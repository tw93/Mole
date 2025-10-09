#!/bin/bash
# Mole - Disk Space Analyzer Module
# Fast disk analysis with mdfind + du hybrid approach

set -euo pipefail

# Fix locale issues (avoid Perl warnings on non-English systems)
export LC_ALL=C
export LANG=C

# Get script directory for sourcing libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$SCRIPT_DIR")/lib"

# Source required libraries
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"

# Constants
readonly CACHE_DIR="${HOME}/.config/mole/cache"
readonly TEMP_PREFIX="/tmp/mole_analyze_$$"
readonly MIN_LARGE_FILE_SIZE="1000000000"    # 1GB
readonly MIN_MEDIUM_FILE_SIZE="100000000"     # 100MB
readonly MIN_SMALL_FILE_SIZE="10000000"       # 10MB

# Emoji badges for list displays only
readonly BADGE_DIR="🍞"
readonly BADGE_FILE="📔"
readonly BADGE_MEDIA="🌁"
readonly BADGE_BUNDLE="🥜"
readonly BADGE_LOG="📝"
readonly BADGE_APP="🐣"

# Global state
declare -a SCAN_RESULTS=()
declare -a DIR_RESULTS=()
declare -a LARGE_FILES=()
declare SCAN_PID=""
declare TOTAL_SIZE=0
declare CURRENT_PATH="$HOME"
declare CURRENT_DEPTH=1

# UI State
declare CURSOR_POS=0
declare SORT_MODE="size"  # size, name, time
declare VIEW_MODE="overview"  # overview, detail, files

# Cleanup on exit
cleanup() {
    show_cursor
    # Cleanup temp files using glob pattern (analyze uses many temp files)
    rm -f "$TEMP_PREFIX"* 2>/dev/null || true
    if [[ -n "$SCAN_PID" ]] && kill -0 "$SCAN_PID" 2>/dev/null; then
        kill "$SCAN_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

# ============================================================================
# Scanning Functions
# ============================================================================

# Fast scan using mdfind for large files
scan_large_files() {
    local target_path="$1"
    local output_file="$2"

    if ! command -v mdfind &>/dev/null; then
        return 1
    fi

    # Scan files > 1GB
    local file=""
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local size=$(stat -f%z "$file" 2>/dev/null || echo "0")
            echo "$size|$file"
        fi
    done < <(mdfind -onlyin "$target_path" "kMDItemFSSize > $MIN_LARGE_FILE_SIZE" 2>/dev/null) | \
        sort -t'|' -k1 -rn > "$output_file"
}

# Scan medium files (100MB - 1GB)
scan_medium_files() {
    local target_path="$1"
    local output_file="$2"

    if ! command -v mdfind &>/dev/null; then
        return 1
    fi

    local file=""
    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            local size=$(stat -f%z "$file" 2>/dev/null || echo "0")
            echo "$size|$file"
        fi
    done < <(mdfind -onlyin "$target_path" \
        "kMDItemFSSize > $MIN_MEDIUM_FILE_SIZE && kMDItemFSSize < $MIN_LARGE_FILE_SIZE" 2>/dev/null) | \
        sort -t'|' -k1 -rn > "$output_file"
}

# Scan top-level directories with du (optimized with parallel)
scan_directories() {
    local target_path="$1"
    local output_file="$2"
    local depth="${3:-1}"

    # Check if we can use parallel processing
    if command -v xargs &>/dev/null && [[ $depth -eq 1 ]]; then
        # Fast parallel scan for depth 1
        find "$target_path" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | \
            xargs -0 -P 4 -I {} du -sk {} 2>/dev/null | \
            sort -rn | \
            while IFS=$'\t' read -r size path; do
                echo "$((size * 1024))|$path"
            done > "$output_file"
    else
        # Standard du scan
        du -d "$depth" -k "$target_path" 2>/dev/null | \
            sort -rn | \
            while IFS=$'\t' read -r size path; do
                # Skip if path is the target itself at depth > 0
                if [[ "$path" != "$target_path" ]]; then
                    echo "$((size * 1024))|$path"
                fi
            done > "$output_file"
    fi
}

# Aggregate files by directory
aggregate_by_directory() {
    local file_list="$1"
    local output_file="$2"

    awk -F'|' '{
        path = $2
        size = $1
        # Get parent directory
        n = split(path, parts, "/")
        dir = ""
        for(i=1; i<n; i++) {
            dir = dir parts[i] "/"
        }
        if(dir) {
            dir_count[dir]++
            dir_size[dir] += size
        }
    }
    END {
        for(dir in dir_count) {
            printf "%d|%s|%d\n", dir_size[dir], dir, dir_count[dir]
        }
    }' "$file_list" | sort -t'|' -k1 -rn > "$output_file"
}

# Get cache file path for a directory
get_cache_file() {
    local target_path="$1"
    local path_hash=$(echo "$target_path" | md5 2>/dev/null || echo "$target_path" | shasum | cut -d' ' -f1)
    echo "$CACHE_DIR/scan_${path_hash}.cache"
}

# Check if cache is valid (less than 1 hour old)
is_cache_valid() {
    local cache_file="$1"
    local max_age="${2:-3600}"  # Default 1 hour

    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi

    local cache_age=$(($(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || echo 0)))
    if [[ $cache_age -lt $max_age ]]; then
        return 0
    fi

    return 1
}

# Save scan results to cache
save_to_cache() {
    local cache_file="$1"
    local temp_large="$TEMP_PREFIX.large"
    local temp_medium="$TEMP_PREFIX.medium"
    local temp_dirs="$TEMP_PREFIX.dirs"
    local temp_agg="$TEMP_PREFIX.agg"

    # Create cache directory
    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || return 1

    # Bundle all scan results into cache file
    {
        echo "### LARGE ###"
        [[ -f "$temp_large" ]] && cat "$temp_large"
        echo "### MEDIUM ###"
        [[ -f "$temp_medium" ]] && cat "$temp_medium"
        echo "### DIRS ###"
        [[ -f "$temp_dirs" ]] && cat "$temp_dirs"
        echo "### AGG ###"
        [[ -f "$temp_agg" ]] && cat "$temp_agg"
    } > "$cache_file" 2>/dev/null
}

# Load scan results from cache
load_from_cache() {
    local cache_file="$1"
    local temp_large="$TEMP_PREFIX.large"
    local temp_medium="$TEMP_PREFIX.medium"
    local temp_dirs="$TEMP_PREFIX.dirs"
    local temp_agg="$TEMP_PREFIX.agg"

    local section=""
    while IFS= read -r line; do
        case "$line" in
            "### LARGE ###") section="large" ;;
            "### MEDIUM ###") section="medium" ;;
            "### DIRS ###") section="dirs" ;;
            "### AGG ###") section="agg" ;;
            *)
                case "$section" in
                    "large") echo "$line" >> "$temp_large" ;;
                    "medium") echo "$line" >> "$temp_medium" ;;
                    "dirs") echo "$line" >> "$temp_dirs" ;;
                    "agg") echo "$line" >> "$temp_agg" ;;
                esac
                ;;
        esac
    done < "$cache_file"
}

# Main scan coordinator
perform_scan() {
    local target_path="$1"
    local force_rescan="${2:-false}"

    # Check cache first
    local cache_file=$(get_cache_file "$target_path")
    if [[ "$force_rescan" != "true" ]] && is_cache_valid "$cache_file" 3600; then
        log_info "Loading cached results for $target_path..."
        load_from_cache "$cache_file"
        log_success "Cache loaded!"
        return 0
    fi

    log_info "Analyzing disk space in $target_path..."
    echo ""

    # Create temp files
    local temp_large="$TEMP_PREFIX.large"
    local temp_medium="$TEMP_PREFIX.medium"
    local temp_dirs="$TEMP_PREFIX.dirs"
    local temp_agg="$TEMP_PREFIX.agg"

    # Start parallel scans
    {
        scan_large_files "$target_path" "$temp_large" &
        scan_medium_files "$target_path" "$temp_medium" &
        scan_directories "$target_path" "$temp_dirs" "$CURRENT_DEPTH" &
        wait
    } &
    SCAN_PID=$!

    # Show spinner with progress while scanning
    local spinner_chars
    spinner_chars="$(mo_spinner_chars)"
    local i=0
    local elapsed=0
    hide_cursor

    # Progress messages (short and dynamic)
    local messages=(
        "Finding large files"
        "Scanning directories"
        "Calculating sizes"
        "Finishing up"
    )
    local msg_idx=0

    while kill -0 "$SCAN_PID" 2>/dev/null; do
        # Show different messages based on elapsed time
        local current_msg=""
        if [[ $elapsed -lt 5 ]]; then
            current_msg="${messages[0]}"
        elif [[ $elapsed -lt 15 ]]; then
            current_msg="${messages[1]}"
        elif [[ $elapsed -lt 25 ]]; then
            current_msg="${messages[2]}"
        else
            current_msg="${messages[3]}"
        fi

        printf "\r${BLUE}%s${NC} %s" \
            "${spinner_chars:$i:1}" "$current_msg"

        i=$(( (i + 1) % 10 ))
        ((elapsed++))
        sleep 0.1
    done
    wait "$SCAN_PID" 2>/dev/null || true
    printf "\r%80s\r" ""  # Clear spinner line
    show_cursor

    # Aggregate results
    if [[ -f "$temp_large" ]] && [[ -s "$temp_large" ]]; then
        aggregate_by_directory "$temp_large" "$temp_agg"
    fi

    # Save to cache
    save_to_cache "$cache_file"

    log_success "Scan complete!"
}

# ============================================================================
# Visualization Functions
# ============================================================================

# Generate progress bar
generate_bar() {
    local current="$1"
    local max="$2"
    local width="${3:-20}"

    if [[ "$max" -eq 0 ]]; then
        printf "%${width}s" "" | tr ' ' '░'
        return
    fi

    local filled=$((current * width / max))
    local empty=$((width - filled))

    # Ensure non-negative
    [[ $filled -lt 0 ]] && filled=0
    [[ $empty -lt 0 ]] && empty=0

    local bar=""
    if [[ $filled -gt 0 ]]; then
        bar=$(printf "%${filled}s" "" | tr ' ' '█')
    fi
    if [[ $empty -gt 0 ]]; then
        bar="${bar}$(printf "%${empty}s" "" | tr ' ' '░')"
    fi

    echo "$bar"
}

# Calculate percentage
calc_percentage() {
    local part="$1"
    local total="$2"

    if [[ "$total" -eq 0 ]]; then
        echo "0"
        return
    fi

    echo "$part" "$total" | awk '{printf "%.1f", ($1/$2)*100}'
}

# Display large files summary (compact version)
display_large_files_compact() {
    local temp_large="$TEMP_PREFIX.large"

    if [[ ! -f "$temp_large" ]] || [[ ! -s "$temp_large" ]]; then
        return
    fi

    log_header "Top Large Files"
    echo ""

    local count=0
    local total_size=0
    local total_count=$(wc -l < "$temp_large" | tr -d ' ')

    # Calculate total size
    while IFS='|' read -r size path; do
        ((total_size += size))
    done < "$temp_large"

    # Show top 5 only
    while IFS='|' read -r size path; do
        if [[ $count -ge 5 ]]; then
            break
        fi

        local human_size=$(bytes_to_human "$size")
        local filename=$(basename "$path")
        local dirname=$(basename "$(dirname "$path")")

        local info=$(get_file_info "$path")
        local badge="${info%|*}"
        printf "  ${GREEN}%-8s${NC} %s %-40s ${GRAY}%s${NC}\n" \
            "$human_size" "$badge" "${filename:0:40}" "$dirname"

        ((count++))
    done < "$temp_large"

    echo ""
    local total_human=$(bytes_to_human "$total_size")
    echo "  ${GRAY}Found $total_count large files (>1GB), totaling $total_human${NC}"
    echo ""
}

# Display large files summary (full version)
display_large_files() {
    local temp_large="$TEMP_PREFIX.large"

    if [[ ! -f "$temp_large" ]] || [[ ! -s "$temp_large" ]]; then
        log_header "Large Files (>1GB)"
        echo ""
        echo "  ${GRAY}No files larger than 1GB found${NC}"
        echo ""
        return
    fi

    log_header "Large Files (>1GB)"
    echo ""

    local count=0
    local max_size=0

    # Get max size for progress bar
    max_size=$(head -1 "$temp_large" | cut -d'|' -f1)
    [[ -z "$max_size" ]] && max_size=1

    while IFS='|' read -r size path; do
        if [[ $count -ge 10 ]]; then
            break
        fi

        local human_size=$(bytes_to_human "$size")
        local percentage=$(calc_percentage "$size" "$max_size")
        local bar=$(generate_bar "$size" "$max_size" 20)
        local filename=$(basename "$path")
        local dirname=$(dirname "$path" | sed "s|^$HOME|~|")

        local info=$(get_file_info "$path")
        local badge="${info%|*}"
        printf "  %s [${GREEN}%s${NC}] %7s\n" "$bar" "$human_size" ""
        printf "    %s %s\n" "$badge" "$filename"
        printf "    ${GRAY}%s${NC}\n\n" "$dirname"

        ((count++))
    done < "$temp_large"

    # Show total count
    local total_count=$(wc -l < "$temp_large" | tr -d ' ')
    if [[ $total_count -gt 10 ]]; then
        echo "  ${GRAY}... and $((total_count - 10)) more files${NC}"
        echo ""
    fi
}

# Display directory summary (compact version)
display_directories_compact() {
    local temp_dirs="$TEMP_PREFIX.dirs"

    if [[ ! -f "$temp_dirs" ]] || [[ ! -s "$temp_dirs" ]]; then
        return
    fi

    log_header "Top Directories"
    echo ""

    local count=0
    local total_size=0

    # Calculate total
    while IFS='|' read -r size path; do
        ((total_size += size))
    done < "$temp_dirs"
    [[ $total_size -eq 0 ]] && total_size=1

    # Show top 8 directories in compact format
    while IFS='|' read -r size path; do
        if [[ $count -ge 8 ]]; then
            break
        fi

        local human_size=$(bytes_to_human "$size")
        local percentage=$(calc_percentage "$size" "$total_size")
        local dirname=$(basename "$path")

        # Simple bar (10 chars)
        local bar_width=10
        local percentage_int=${percentage%.*}  # Remove decimal part
        local filled=$((percentage_int * bar_width / 100))
        [[ $filled -gt $bar_width ]] && filled=$bar_width
        [[ $filled -lt 0 ]] && filled=0
        local empty=$((bar_width - filled))
        [[ $empty -lt 0 ]] && empty=0
        local bar=""
        if [[ $filled -gt 0 ]]; then
            bar=$(printf "%${filled}s" "" | tr ' ' '█')
        fi
        if [[ $empty -gt 0 ]]; then
            bar="${bar}$(printf "%${empty}s" "" | tr ' ' '░')"
        fi

        printf "  ${BLUE}%-8s${NC} %s ${GRAY}%3s%%${NC} %s %s\n" \
            "$human_size" "$bar" "$percentage" "$BADGE_DIR" "$dirname"

        ((count++))
    done < "$temp_dirs"
    echo ""
}

# Display directory summary (full version)
display_directories() {
    local temp_dirs="$TEMP_PREFIX.dirs"

    if [[ ! -f "$temp_dirs" ]] || [[ ! -s "$temp_dirs" ]]; then
        return
    fi

    log_header "Top Directories"
    echo ""

    local count=0
    local max_size=0
    local total_size=0

    # Calculate total and max for percentages
    max_size=$(head -1 "$temp_dirs" | cut -d'|' -f1)
    [[ -z "$max_size" ]] && max_size=1

    while IFS='|' read -r size path; do
        ((total_size += size))
    done < "$temp_dirs"

    [[ $total_size -eq 0 ]] && total_size=1

    # Display directories
    while IFS='|' read -r size path; do
        if [[ $count -ge 15 ]]; then
            break
        fi

        local human_size=$(bytes_to_human "$size")
        local percentage=$(calc_percentage "$size" "$total_size")
        local bar=$(generate_bar "$size" "$max_size" 20)
        local display_path=$(echo "$path" | sed "s|^$HOME|~|")
        local dirname=$(basename "$path")

        printf "  %s [${BLUE}%s${NC}] %5s%%\n" "$bar" "$human_size" "$percentage"
        printf "    %s %s\n\n" "$BADGE_DIR" "$display_path"

        ((count++))
    done < "$temp_dirs"
}

# Display hotspot directories (many large files)
display_hotspots() {
    local temp_agg="$TEMP_PREFIX.agg"

    if [[ ! -f "$temp_agg" ]] || [[ ! -s "$temp_agg" ]]; then
        return
    fi

    log_header "High-concentration Hotspot Directories"
    echo ""

    local count=0
    while IFS='|' read -r size path file_count; do
        if [[ $count -ge 8 ]]; then
            break
        fi

        local human_size=$(bytes_to_human "$size")
        local display_path=$(echo "$path" | sed "s|^$HOME|~|")

        printf "  %s\n" "$display_path"
        printf "     ${GREEN}%s${NC} in ${YELLOW}%d${NC} large files\n\n" \
            "$human_size" "$file_count"

        ((count++))
    done < "$temp_agg"
}

# Display smart cleanup suggestions (compact version)
display_cleanup_suggestions_compact() {
    local suggestions_count=0
    local top_suggestion=""
    local potential_space=0
    local action_command=""

    # Check common cache locations (only if analyzing Library/Caches or system paths)
    if [[ "$CURRENT_PATH" == "$HOME/Library/Caches"* ]] || [[ "$CURRENT_PATH" == "$HOME/Library"* ]]; then
        if [[ -d "$HOME/Library/Caches" ]]; then
            local cache_size=$(du -sk "$HOME/Library/Caches" 2>/dev/null | cut -f1)
            if [[ $cache_size -gt 1048576 ]]; then  # > 1GB
                local human=$(bytes_to_human $((cache_size * 1024)))
                top_suggestion="Clear app caches ($human)"
                action_command="mole clean"
                ((potential_space += cache_size * 1024))
                ((suggestions_count++))
            fi
        fi
    fi

    # Check Downloads folder (only if analyzing Downloads)
    if [[ "$CURRENT_PATH" == "$HOME/Downloads"* ]]; then
        local old_files=$(find "$CURRENT_PATH" -type f -mtime +90 2>/dev/null | wc -l | tr -d ' ')
        if [[ $old_files -gt 0 ]]; then
            [[ -z "$top_suggestion" ]] && top_suggestion="$old_files files older than 90 days found"
            [[ -z "$action_command" ]] && action_command="manually review old files"
            ((suggestions_count++))
        fi
    fi

    # Check for large disk images in current path
    if command -v mdfind &>/dev/null; then
        local dmg_count=$(mdfind -onlyin "$CURRENT_PATH" \
            "kMDItemFSSize > 500000000 && kMDItemDisplayName == '*.dmg'" 2>/dev/null | wc -l | tr -d ' ')
        if [[ $dmg_count -gt 0 ]]; then
            local dmg_size=$(mdfind -onlyin "$CURRENT_PATH" \
                "kMDItemFSSize > 500000000 && kMDItemDisplayName == '*.dmg'" 2>/dev/null | \
                xargs stat -f%z 2>/dev/null | awk '{sum+=$1} END {print sum}')
            local dmg_human=$(bytes_to_human "$dmg_size")
            [[ -z "$top_suggestion" ]] && top_suggestion="$dmg_count DMG files ($dmg_human) can be removed"
            [[ -z "$action_command" ]] && action_command="manually delete DMG files"
            ((potential_space += dmg_size))
            ((suggestions_count++))
        fi
    fi

    # Check Xcode (only if in developer paths)
    if [[ "$CURRENT_PATH" == "$HOME/Library/Developer"* ]] && [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
        local xcode_size=$(du -sk "$HOME/Library/Developer/Xcode/DerivedData" 2>/dev/null | cut -f1)
        if [[ $xcode_size -gt 10485760 ]]; then
            local xcode_human=$(bytes_to_human $((xcode_size * 1024)))
            [[ -z "$top_suggestion" ]] && top_suggestion="Xcode cache ($xcode_human) can be cleared"
            [[ -z "$action_command" ]] && action_command="mole clean"
            ((potential_space += xcode_size * 1024))
            ((suggestions_count++))
        fi
    fi

    # Check for duplicates in current path
    if command -v mdfind &>/dev/null; then
        local dup_count=$(mdfind -onlyin "$CURRENT_PATH" "kMDItemFSSize > 10000000" 2>/dev/null | \
            xargs -I {} stat -f "%z" {} 2>/dev/null | sort | uniq -d | wc -l | tr -d ' ')
        if [[ $dup_count -gt 5 ]]; then
            [[ -z "$top_suggestion" ]] && top_suggestion="$dup_count potential duplicate files detected"
            ((suggestions_count++))
        fi
    fi

    if [[ $suggestions_count -gt 0 ]]; then
        log_header "Quick Insights"
        echo ""
        echo "  ${YELLOW}$top_suggestion${NC}"
        if [[ $suggestions_count -gt 1 ]]; then
            echo "  ${GRAY}... and $((suggestions_count - 1)) more insights${NC}"
        fi
        if [[ $potential_space -gt 0 ]]; then
            local space_human=$(bytes_to_human "$potential_space")
            echo "  ${GREEN}Potential recovery: ~$space_human${NC}"
        fi
        echo ""
        if [[ -n "$action_command" ]]; then
            if [[ "$action_command" == "mole clean" ]]; then
                echo "  ${GRAY}→ Run${NC} ${YELLOW}mole clean${NC} ${GRAY}to cleanup system files${NC}"
            else
                echo "  ${GRAY}→ Review and ${NC}${YELLOW}$action_command${NC}"
            fi
        fi
        echo ""
    fi
}

# Display smart cleanup suggestions (full version)
display_cleanup_suggestions() {
    log_header "Smart Cleanup Suggestions"
    echo ""

    local suggestions=()

    # Check common cache locations
    if [[ -d "$HOME/Library/Caches" ]]; then
        local cache_size=$(du -sk "$HOME/Library/Caches" 2>/dev/null | cut -f1)
        if [[ $cache_size -gt 1048576 ]]; then  # > 1GB
            local human=$(bytes_to_human $((cache_size * 1024)))
            suggestions+=("  Clear application caches: $human")
        fi
    fi

    # Check Downloads folder
    if [[ -d "$HOME/Downloads" ]]; then
        local old_files=$(find "$HOME/Downloads" -type f -mtime +90 2>/dev/null | wc -l | tr -d ' ')
        if [[ $old_files -gt 0 ]]; then
            suggestions+=("  Clean old downloads: $old_files files older than 90 days")
        fi
    fi

    # Check for large disk images
    if command -v mdfind &>/dev/null; then
        local dmg_count=$(mdfind -onlyin "$HOME" \
            "kMDItemFSSize > 500000000 && kMDItemDisplayName == '*.dmg'" 2>/dev/null | wc -l | tr -d ' ')
        if [[ $dmg_count -gt 0 ]]; then
            suggestions+=("  Remove disk images: $dmg_count DMG files >500MB")
        fi
    fi

    # Check Xcode derived data
    if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
        local xcode_size=$(du -sk "$HOME/Library/Developer/Xcode/DerivedData" 2>/dev/null | cut -f1)
        if [[ $xcode_size -gt 10485760 ]]; then  # > 10GB
            local human=$(bytes_to_human $((xcode_size * 1024)))
            suggestions+=("  Clear Xcode cache: $human")
        fi
    fi

    # Check iOS device backups
    if [[ -d "$HOME/Library/Application Support/MobileSync/Backup" ]]; then
        local backup_size=$(du -sk "$HOME/Library/Application Support/MobileSync/Backup" 2>/dev/null | cut -f1)
        if [[ $backup_size -gt 5242880 ]]; then  # > 5GB
            local human=$(bytes_to_human $((backup_size * 1024)))
            suggestions+=("  📱 Review iOS backups: $human")
        fi
    fi

    # Check for duplicate files (by size, quick heuristic)
    if command -v mdfind &>/dev/null; then
        local temp_dup="$TEMP_PREFIX.dup_check"
        mdfind -onlyin "$CURRENT_PATH" "kMDItemFSSize > 10000000" 2>/dev/null | \
            xargs -I {} stat -f "%z" {} 2>/dev/null | \
            sort | uniq -d | wc -l | tr -d ' ' > "$temp_dup" 2>/dev/null || echo "0" > "$temp_dup"
        local dup_count=$(cat "$temp_dup" 2>/dev/null || echo "0")
        if [[ $dup_count -gt 5 ]]; then
            suggestions+=("  ♻️ Possible duplicates: $dup_count size matches in large files (>10MB)")
        fi
    fi

    # Display suggestions
    if [[ ${#suggestions[@]} -gt 0 ]]; then
        printf '%s\n' "${suggestions[@]}"
        echo ""
        echo "  Tip: Run 'mole clean' to perform cleanup operations"
    else
        echo "  ${GREEN}✓${NC} No obvious cleanup opportunities found"
    fi
    echo ""
}

# Display overall disk situation summary
display_disk_summary() {
    local temp_large="$TEMP_PREFIX.large"
    local temp_dirs="$TEMP_PREFIX.dirs"

    # Calculate stats
    local total_large_size=0
    local total_large_count=0
    local total_dirs_size=0
    local total_dirs_count=0

    if [[ -f "$temp_large" ]]; then
        total_large_count=$(wc -l < "$temp_large" 2>/dev/null | tr -d ' ')
        while IFS='|' read -r size path; do
            ((total_large_size += size))
        done < "$temp_large"
    fi

    if [[ -f "$temp_dirs" ]]; then
        total_dirs_count=$(wc -l < "$temp_dirs" 2>/dev/null | tr -d ' ')
        while IFS='|' read -r size path; do
            ((total_dirs_size += size))
        done < "$temp_dirs"
    fi

    log_header "Disk Situation"

    local target_display=$(echo "$CURRENT_PATH" | sed "s|^$HOME|~|")
    echo "  ${BLUE}Scanning:${NC} $target_display | ${BLUE}Free:${NC} $(get_free_space)"

    if [[ $total_large_count -gt 0 ]]; then
        local large_human=$(bytes_to_human "$total_large_size")
        echo "  ${BLUE}Large Files:${NC} $total_large_count files ($large_human) | ${BLUE}Total:${NC} $(bytes_to_human "$total_dirs_size") in $total_dirs_count dirs"
    elif [[ $total_dirs_size -gt 0 ]]; then
        echo "  ${BLUE}Total Scanned:${NC} $(bytes_to_human "$total_dirs_size") across $total_dirs_count directories"
    fi
    echo ""
}

# Get file type icon and description
get_file_info() {
    local path="$1"
    local ext="${path##*.}"
    local badge="$BADGE_FILE"
    local type="File"

    case "$ext" in
        dmg|iso|pkg|zip|tar|gz|rar|7z)
            badge="$BADGE_BUNDLE" ; type="Bundle"
            ;;
        mov|mp4|avi|mkv|webm|jpg|jpeg|png|gif|heic)
            badge="$BADGE_MEDIA" ; type="Media"
            ;;
        pdf|key|ppt|pptx)
            type="Document"
            ;;
        log)
            badge="$BADGE_LOG" ; type="Log"
            ;;
        app)
            badge="$BADGE_APP" ; type="App"
            ;;
    esac

    echo "$badge|$type"
}

# Get file age in human readable format
get_file_age() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "N/A"
        return
    fi

    local mtime=$(stat -f%m "$path" 2>/dev/null || echo "0")
    local now=$(date +%s)
    local diff=$((now - mtime))
    local days=$((diff / 86400))

    if [[ $days -lt 1 ]]; then
        echo "Today"
    elif [[ $days -eq 1 ]]; then
        echo "1 day"
    elif [[ $days -lt 30 ]]; then
        echo "${days}d"
    elif [[ $days -lt 365 ]]; then
        local months=$((days / 30))
        echo "${months}mo"
    else
        local years=$((days / 365))
        echo "${years}yr"
    fi
}

# Display large files in compact table format
display_large_files_table() {
    local temp_large="$TEMP_PREFIX.large"

    if [[ ! -f "$temp_large" ]] || [[ ! -s "$temp_large" ]]; then
        return
    fi

    log_header "What's Taking Up Space"

    # Table header
    printf "  %-4s  %-10s  %-8s  %s\n" "TYPE" "SIZE" "AGE" "FILE"
    printf "  %s\n" "$(printf '%.0s─' {1..80})"

    local count=0
    while IFS='|' read -r size path; do
        if [[ $count -ge 20 ]]; then
            break
        fi

        local human_size=$(bytes_to_human "$size")
        local filename=$(basename "$path")
        local ext="${filename##*.}"
        local age=$(get_file_age "$path")

        # Get file info and badge
        local info=$(get_file_info "$path")
        local badge="${info%|*}"

        # Truncate filename if too long
        if [[ ${#filename} -gt 50 ]]; then
            filename="${filename:0:47}..."
        fi

        # Color based on file type
        local color=""
        case "$ext" in
            dmg|iso|pkg) color="${RED}" ;;
            mov|mp4|avi|mkv|webm|zip|tar|gz|rar|7z) color="${YELLOW}" ;;
            log) color="${GRAY}" ;;
            *) color="${NC}" ;;
        esac

        printf "  %b%-4s  %-10s  %-8s  %s${NC}\n" \
            "$color" "$badge" "$human_size" "$age" "$filename"

        ((count++))
    done < "$temp_large"

    local total=$(wc -l < "$temp_large" | tr -d ' ')
    if [[ $total -gt 20 ]]; then
        echo "  ${GRAY}... $((total - 20)) more files${NC}"
    fi
    echo ""
}

# Display unified directory view in table format
display_unified_directories() {
    local temp_dirs="$TEMP_PREFIX.dirs"

    if [[ ! -f "$temp_dirs" ]] || [[ ! -s "$temp_dirs" ]]; then
        return
    fi

    # Calculate total
    local total_size=0
    while IFS='|' read -r size path; do
        ((total_size += size))
    done < "$temp_dirs"
    [[ $total_size -eq 0 ]] && total_size=1

    echo "  ${YELLOW}Top Directories:${NC}"

    # Table header
    printf "  %-30s  %5s  %10s  %s\n" "DIRECTORY" "%" "SIZE" "CHART"
    printf "  %s\n" "$(printf '%.0s─' {1..75})"

    # Show top 10 directories
    local count=0
    local chart_width=20
    while IFS='|' read -r size path; do
        if [[ $count -ge 10 ]]; then
            break
        fi

        local percentage=$((size * 100 / total_size))
        local bar_width=$((percentage * chart_width / 100))
        [[ $bar_width -lt 1 ]] && bar_width=1

        local dirname=$(basename "$path")
        local human_size=$(bytes_to_human "$size")

        # Build compact bar
        local bar=""
        if [[ $bar_width -gt 0 ]]; then
            bar=$(printf "%${bar_width}s" "" | tr ' ' '▓')
        fi
        local empty=$((chart_width - bar_width))
        if [[ $empty -gt 0 ]]; then
            bar="${bar}$(printf "%${empty}s" "" | tr ' ' '░')"
        fi

        # Truncate dirname if too long
        local display_name="$dirname"
        if [[ ${#dirname} -gt 28 ]]; then
            display_name="${dirname:0:25}..."
        fi

        # Color based on percentage
        local color="${NC}"
        if [[ $percentage -gt 50 ]]; then
            color="${RED}"
        elif [[ $percentage -gt 20 ]]; then
            color="${YELLOW}"
        else
            color="${BLUE}"
        fi

        printf "  %b%-30s  %4d%%  %10s  %s${NC}\n" \
            "$color" "$display_name" "$percentage" "$human_size" "$bar"

        ((count++))
    done < "$temp_dirs"
    echo ""
}

# Display context-aware recommendations
display_recommendations() {
    echo "  ${YELLOW}Quick Actions:${NC}"

    if [[ "$CURRENT_PATH" == "$HOME/Downloads"* ]]; then
        echo "    → Delete ${RED}[Can Delete]${NC} items (installers/DMG)"
        echo "    → Review ${YELLOW}[Review]${NC} items (videos/archives)"
    elif [[ "$CURRENT_PATH" == "$HOME/Library"* ]]; then
        echo "    → Run ${GREEN}mole clean${NC} to clear caches safely"
        echo "    → Check Xcode/developer caches if applicable"
    else
        echo "    → Review ${RED}[Can Delete]${NC} and ${YELLOW}[Review]${NC} items"
        echo "    → Run ${GREEN}mole analyze ~/Library${NC} to check caches"
    fi
    echo ""
}

# Display space chart (visual tree map style)
display_space_chart() {
    local temp_dirs="$TEMP_PREFIX.dirs"

    if [[ ! -f "$temp_dirs" ]] || [[ ! -s "$temp_dirs" ]]; then
        return
    fi

    log_header "Space Distribution"
    echo ""

    # Calculate total
    local total_size=0
    while IFS='|' read -r size path; do
        ((total_size += size))
    done < "$temp_dirs"
    [[ $total_size -eq 0 ]] && total_size=1

    # Show top 5 as blocks
    local count=0
    local chart_width=50
    while IFS='|' read -r size path; do
        if [[ $count -ge 5 ]]; then
            break
        fi

        local percentage=$((size * 100 / total_size))
        local bar_width=$((percentage * chart_width / 100))
        [[ $bar_width -lt 1 ]] && bar_width=1

        local dirname=$(basename "$path")
        local human_size=$(bytes_to_human "$size")

        # Build visual bar
        local bar=""
        if [[ $bar_width -gt 0 ]]; then
            bar=$(printf "%${bar_width}s" "" | tr ' ' '█')
        fi

        printf "  ${BLUE}%-15s${NC} %3d%% %s  %s\n" \
            "${dirname:0:15}" "$percentage" "$bar" "$human_size"

        ((count++))
    done < "$temp_dirs"
    echo ""
}

# Display recent large files (added in last 30 days)
display_recent_large_files() {
    log_header "Recent Large Files (Last 30 Days)"
    echo ""

    if ! command -v mdfind &>/dev/null; then
        echo "  ${YELLOW}Note: mdfind not available${NC}"
        echo ""
        return
    fi

    local temp_recent="$TEMP_PREFIX.recent"

    # Find files created in last 30 days, larger than 100MB
    mdfind -onlyin "$CURRENT_PATH" \
        "kMDItemFSSize > 100000000 && kMDItemContentCreationDate >= \$time.today(-30)" 2>/dev/null | \
        while IFS= read -r file; do
            if [[ -f "$file" ]]; then
                local size=$(stat -f%z "$file" 2>/dev/null || echo "0")
                local mtime=$(stat -f%m "$file" 2>/dev/null || echo "0")
                echo "$size|$mtime|$file"
            fi
        done | sort -t'|' -k1 -rn | head -10 > "$temp_recent"

    if [[ ! -s "$temp_recent" ]]; then
        echo "  ${GRAY}No large files created recently${NC}"
        echo ""
        return
    fi

    local count=0
    while IFS='|' read -r size mtime path; do
        local human_size=$(bytes_to_human "$size")
        local filename=$(basename "$path")
        local dirname=$(dirname "$path" | sed "s|^$HOME|~|")
        local days_ago=$(( ($(date +%s) - mtime) / 86400 ))

        local info=$(get_file_info "$path")
        local badge="${info%|*}"

        printf "  %s %s ${GRAY}(%s)${NC}\n" "$badge" "$filename" "$human_size"
        printf "     ${GRAY}%s - %d days ago${NC}\n\n" "$dirname" "$days_ago"

        ((count++))
    done < "$temp_recent"
}

# ============================================================================
# Interactive Navigation
# ============================================================================

# Get list of subdirectories
get_subdirectories() {
    local target="$1"
    local temp_file="$2"

    find "$target" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | \
        while IFS= read -r dir; do
            local size=$(du -sk "$dir" 2>/dev/null | cut -f1)
            echo "$((size * 1024))|$dir"
        done | sort -t'|' -k1 -rn > "$temp_file"
}

# Display directory list for selection
display_directory_list() {
    local temp_dirs="$TEMP_PREFIX.dirs"
    local cursor_pos="${1:-0}"

    if [[ ! -f "$temp_dirs" ]] || [[ ! -s "$temp_dirs" ]]; then
        return 1
    fi

    local idx=0
    local max_size=0
    local total_size=0

    # Calculate totals
    max_size=$(head -1 "$temp_dirs" | cut -d'|' -f1)
    [[ -z "$max_size" ]] && max_size=1
    while IFS='|' read -r size path; do
        ((total_size += size))
    done < "$temp_dirs"
    [[ $total_size -eq 0 ]] && total_size=1

    # Display with cursor
    while IFS='|' read -r size path; do
        local human_size=$(bytes_to_human "$size")
        local percentage=$(calc_percentage "$size" "$total_size")
        local bar=$(generate_bar "$size" "$max_size" 20)
        local display_path=$(echo "$path" | sed "s|^$HOME|~|")
        local dirname=$(basename "$path")

        # Highlight selected line
        if [[ $idx -eq $cursor_pos ]]; then
            printf "  ${BLUE}▶${NC} %s [${GREEN}%s${NC}] %5s%%  %s\n" \
                "$bar" "$human_size" "$percentage" "$dirname"
        else
            printf "    %s [${BLUE}%s${NC}] %5s%%  %s\n" \
                "$bar" "$human_size" "$percentage" "$dirname"
        fi

        ((idx++))
        if [[ $idx -ge 15 ]]; then
            break
        fi
    done < "$temp_dirs"

    return 0
}

# Get path at cursor position
get_path_at_cursor() {
    local cursor_pos="$1"
    local temp_dirs="$TEMP_PREFIX.dirs"

    if [[ ! -f "$temp_dirs" ]]; then
        return 1
    fi

    local idx=0
    while IFS='|' read -r size path; do
        if [[ $idx -eq $cursor_pos ]]; then
            echo "$path"
            return 0
        fi
        ((idx++))
    done < "$temp_dirs"

    return 1
}

# Count available directories
count_directories() {
    local temp_dirs="$TEMP_PREFIX.dirs"
    if [[ ! -f "$temp_dirs" ]]; then
        echo "0"
        return
    fi
    local count=$(wc -l < "$temp_dirs" | tr -d ' ')
    [[ $count -gt 15 ]] && count=15
    echo "$count"
}

# Display interactive menu
display_interactive_menu() {
    clear_screen

    log_header "Disk Space Analyzer"
    echo ""
    echo "Current: ${BLUE}$(echo "$CURRENT_PATH" | sed "s|^$HOME|~|")${NC}"
    echo ""

    # Show navigation hints
    echo "${GRAY}↑↓ Navigate | → Drill Down | ← Go Back | f Files | t Types | q Quit${NC}"
    echo ""

    # Display results based on view mode
    case "$VIEW_MODE" in
        "navigate")
            log_header "Select Directory"
            echo ""
            display_directory_list "$CURSOR_POS"
            ;;
        "files")
            display_large_files
            ;;
        "types")
            display_file_types
            ;;
        *)
            display_large_files
            display_directories
            display_hotspots
            display_cleanup_suggestions
            ;;
    esac
}

# Analyze file types
display_file_types() {
    local temp_types="$TEMP_PREFIX.types"

    log_header "File Types Analysis"
    echo ""

    if ! command -v mdfind &>/dev/null; then
        echo "  ${YELLOW}Note: mdfind not available, limited analysis${NC}"
        return
    fi

    # Analyze common file types (bash 3.2 compatible - no associative arrays)
    local -a type_names=("Videos" "Images" "Archives" "Documents" "Audio")
    
    local type_name
    for type_name in "${type_names[@]}"; do
        local query=""
        local badge="$BADGE_FILE"
        
        # Map type name to query and badge
        case "$type_name" in
            "Videos")
                query="kMDItemContentType == 'public.movie' || kMDItemContentType == 'public.video'"
                badge="$BADGE_MEDIA"
                ;;
            "Images")
                query="kMDItemContentType == 'public.image'"
                badge="$BADGE_MEDIA"
                ;;
            "Archives")
                query="kMDItemContentType == 'public.archive' || kMDItemContentType == 'public.zip-archive'"
                badge="$BADGE_BUNDLE"
                ;;
            "Documents")
                query="kMDItemContentType == 'com.adobe.pdf' || kMDItemContentType == 'public.text'"
                badge="$BADGE_FILE"
                ;;
            "Audio")
                query="kMDItemContentType == 'public.audio'"
                badge="🎵"
                ;;
        esac
        
        local files=$(mdfind -onlyin "$CURRENT_PATH" "$query" 2>/dev/null)
        local count=$(echo "$files" | grep -c . || echo "0")
        local total_size=0

        if [[ $count -gt 0 ]]; then
            while IFS= read -r file; do
                if [[ -f "$file" ]]; then
                    local fsize=$(stat -f%z "$file" 2>/dev/null || echo "0")
                    ((total_size += fsize))
                fi
            done <<< "$files"

            if [[ $total_size -gt 0 ]]; then
                local human_size=$(bytes_to_human "$total_size")
                printf "  %s %-12s %8s (%d files)\n" "$badge" "$type_name:" "$human_size" "$count"
            fi
        fi
    done
    echo ""
}

# Read a single key press
read_single_key() {
    local key=""
    # Read single character without waiting for Enter
    if read -rsn1 key 2>/dev/null; then
        echo "$key"
    else
        echo "q"
    fi
}

# Fast scan with progress display - optimized for speed
scan_directory_contents_fast() {
    local dir_path="$1"
    local output_file="$2"
    local max_items="${3:-16}"
    local show_progress="${4:-true}"

    # Auto-detect optimal parallel jobs using common function
    local num_jobs=$(get_optimal_parallel_jobs "io")
    # Cap at reasonable limits for I/O operations
    [[ $num_jobs -gt 24 ]] && num_jobs=24
    [[ $num_jobs -lt 12 ]] && num_jobs=12

    local temp_dirs="$output_file.dirs"
    local temp_files="$output_file.files"

    # Show initial scanning message
    if [[ "$show_progress" == "true" ]]; then
        printf "\033[?25l\033[H\033[J" >&2
        echo "" >&2
        printf "  ${BLUE} | Scanning...${NC}\r" >&2
    fi

    # Ultra-fast file scanning - batch stat for maximum speed
    find "$dir_path" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null | \
        xargs -0 -n 20 -P "$num_jobs" stat -f "%z|file|%N" 2>/dev/null > "$temp_files" &
    local file_pid=$!

    # Smart directory scanning with aggressive optimization
    # Strategy: Fast estimation first, accurate on-demand
    find "$dir_path" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | \
        xargs -0 -n 1 -P "$num_jobs" sh -c '
            dir="$1"
            size=""

            # Ultra-fast strategy: Try du with 1 second timeout only
            du -sk "$dir" 2>/dev/null > /tmp/mole_du_$$ &
            du_pid=$!

            # Wait only 1 second (aggressive!)
            if ! sleep 1 || kill -0 $du_pid 2>/dev/null; then
                # Still running after 1s = large dir, kill it
                kill -9 $du_pid 2>/dev/null || true
                wait $du_pid 2>/dev/null || true
                rm -f /tmp/mole_du_$$ 2>/dev/null
                size=""
            else
                # Completed within 1s, use the result
                size=$(cat /tmp/mole_du_$$ 2>/dev/null | cut -f1)
                rm -f /tmp/mole_du_$$ 2>/dev/null
            fi

            # If timeout or empty, use instant estimation
            if [[ -z "$size" ]] || [[ "$size" -eq 0 ]]; then
                # Ultra-fast: count only immediate files (no recursion)
                # Use + instead of xargs for batch stat (much faster)
                size=$(find "$dir" -type f -maxdepth 1 -print0 2>/dev/null | \
                       xargs -0 stat -f%z 2>/dev/null | \
                       awk "BEGIN{sum=0} {sum+=\$1} END{print int(sum/1024)}")

                # If still 0, mark as unknown but ensure it shows up
                [[ -z "$size" ]] || [[ "$size" -eq 0 ]] && size=1
            fi
            echo "$((size * 1024))|dir|$dir"
        ' _ > "$temp_dirs" 2>/dev/null &
    local dir_pid=$!

    # Show progress while waiting
    if [[ "$show_progress" == "true" ]]; then
        local -a spinner=()
        if [[ -n "${MO_SPINNER_CHARS_ARRAY:-}" ]]; then
            read -r -a spinner <<< "${MO_SPINNER_CHARS_ARRAY}"
        else
            local spinner_chars
            spinner_chars="$(mo_spinner_chars)"
            local chars_len=${#spinner_chars}
            for ((idx=0; idx<chars_len; idx++)); do
                spinner+=("${spinner_chars:idx:1}")
            done
        fi
        [[ ${#spinner[@]} -eq 0 ]] && spinner=('|' '/' '-' '\\')
        local i=0
        local max_wait=30  # Reduced to 30 seconds (fast fail)
        local elapsed=0
        local tick=0
        local spin_len=${#spinner[@]}
        (( spin_len == 0 )) && spinner=('|' '/' '-' '\\') && spin_len=${#spinner[@]}

        while ( kill -0 "$dir_pid" 2>/dev/null || kill -0 "$file_pid" 2>/dev/null ); do
            printf "\r  ${BLUE}Scanning${NC} ${spinner[$((i % spin_len))]} (%ds)" "$elapsed" >&2
            ((i++))
            sleep 0.1  # Faster animation (100ms per frame)
            ((tick++))

            # Update elapsed seconds every 10 ticks (1 second)
            if [[ $((tick % 10)) -eq 0 ]]; then
                ((elapsed++))
            fi

            # Force kill if taking too long (30 seconds for fast response)
            if [[ $elapsed -ge $max_wait ]]; then
                kill -9 "$dir_pid" 2>/dev/null || true
                kill -9 "$file_pid" 2>/dev/null || true
                wait "$dir_pid" 2>/dev/null || true
                wait "$file_pid" 2>/dev/null || true
                printf "\r  ${YELLOW}Large directory - showing estimated sizes${NC}\n" >&2
                sleep 0.3
                break
            fi
        done
        printf "\r\033[K" >&2
        # Ensure cursor stays hidden after clearing spinner
        printf "\033[?25l" >&2
    fi

    # Wait for completion (non-blocking if already killed)
    wait "$file_pid" 2>/dev/null || true
    wait "$dir_pid" 2>/dev/null || true

    # Small delay only if scan was very fast (let user see the spinner briefly)
    if [[ "$show_progress" == "true" ]] && [[ ${elapsed:-0} -lt 1 ]]; then
        sleep 0.2
    fi

    # Combine and sort - only keep top items
    # Ensure we handle empty files gracefully
    > "$output_file"
    if [[ -f "$temp_dirs" ]] || [[ -f "$temp_files" ]]; then
        cat "$temp_dirs" "$temp_files" 2>/dev/null | sort -t'|' -k1 -rn | head -"$max_items" > "$output_file" || true
    fi

    # Cleanup
    rm -f "$temp_dirs" "$temp_files" 2>/dev/null
}

# Calculate directory sizes and update (now only used for deep refresh)
calculate_dir_sizes() {
    local items_file="$1"
    local max_items="${2:-15}"  # Only recalculate first 15 by default
    local temp_file="${items_file}.calc"

    # Since we now scan with actual sizes, this function is mainly for refresh
    # Just re-sort the existing data
    sort -t'|' -k1 -rn "$items_file" > "$temp_file"

    # Only update if source file still exists (might have been deleted if user quit)
    if [[ -f "$items_file" ]]; then
        mv "$temp_file" "$items_file" 2>/dev/null || true
    else
        rm -f "$temp_file" 2>/dev/null || true
    fi
}

# Combine initial scan results (large files + directories) into one list
combine_initial_scan_results() {
    local output_file="$1"
    local temp_large="$TEMP_PREFIX.large"
    local temp_dirs="$TEMP_PREFIX.dirs"

    > "$output_file"

    # Add directories
    if [[ -f "$temp_dirs" ]]; then
        while IFS='|' read -r size path; do
            echo "$size|dir|$path"
        done < "$temp_dirs" >> "$output_file"
    fi

    # Add large files (only files in current directory, not subdirectories)
    if [[ -f "$temp_large" ]]; then
        while IFS='|' read -r size path; do
            # Only include if parent directory is the current scan path
            local parent=$(dirname "$path")
            if [[ "$parent" == "$CURRENT_PATH" ]]; then
                echo "$size|file|$path"
            fi
        done < "$temp_large" >> "$output_file"
    fi

    # Sort by size
    sort -t'|' -k1 -rn "$output_file" -o "$output_file"
}

# Show all volumes overview and let user select
show_volumes_overview() {
    local temp_volumes="$TEMP_PREFIX.volumes"

    # Collect most useful locations (quick display, no size calculation)
    {
        # Priority order for display (prioritized by typical usefulness)
        [[ -d "$HOME" ]] && echo "1000|$HOME|Home Directory"
        [[ -d "$HOME/Downloads" ]] && echo "900|$HOME/Downloads|Downloads"
        [[ -d "/Applications" ]] && echo "800|/Applications|Applications"
        [[ -d "$HOME/Library" ]] && echo "700|$HOME/Library|User Library"
        [[ -d "/Library" ]] && echo "600|/Library|System Library"

        # External volumes (if any)
        if [[ -d "/Volumes" ]]; then
            local vol_priority=500
            find /Volumes -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while IFS= read -r vol; do
                local vol_name=$(basename "$vol")
                echo "$((vol_priority))|$vol|Volume: $vol_name"
                ((vol_priority--))
            done
        fi
    } | sort -t'|' -k1 -rn > "$temp_volumes"

    # Setup alternate screen and hide cursor (keep hidden throughout)
    tput smcup 2>/dev/null || true
    printf "\033[?25l" >&2  # Hide cursor

    cleanup_volumes() {
        printf "\033[?25h" >&2  # Show cursor
        tput rmcup 2>/dev/null || true
    }
    trap cleanup_volumes EXIT INT TERM

    # Force cursor hidden at the start
    stty -echo 2>/dev/null || true

    local cursor=0
    local total_items=$(wc -l < "$temp_volumes" | tr -d ' ')

    while true; do
        # Ensure cursor is always hidden
        printf "\033[?25l" >&2

        # Drain burst input (trackpad scroll -> many arrows)
        type drain_pending_input >/dev/null 2>&1 && drain_pending_input
        # Build output buffer to reduce flicker
        local output=""
        output+="\033[?25l"  # Hide cursor
        output+="\033[H\033[J"
        output+=$'\n'
        output+="\033[0;35mSelect a location to explore\033[0m"$'\n'
        output+=$'\n'

        local idx=0
        while IFS='|' read -r priority path display_name; do
            # Build line (simple display without size)
            local line=""
            if [[ $idx -eq $cursor ]]; then
                line=$(printf "  ${GREEN}▶${NC} ${BLUE}%s${NC}" "$display_name")
            else
                line=$(printf "    ${GRAY}%s${NC}" "$display_name")
            fi
            output+="$line"$'\n'

            ((idx++))
        done < "$temp_volumes"

        output+=$'\n'

        # Output everything at once
        printf "%b" "$output" >&2

        # Read key (suppress any escape sequences that might leak)
        local key
        key=$(read_key 2>/dev/null || echo "OTHER")

        case "$key" in
            "UP")
                ((cursor > 0)) && ((cursor--))
                ;;
            "DOWN")
                ((cursor < total_items - 1)) && ((cursor++))
                ;;
            "ENTER"|"RIGHT")
                # Get selected path and enter it
                local selected_path=""
                idx=0
                while IFS='|' read -r priority path display_name; do
                    if [[ $idx -eq $cursor ]]; then
                        selected_path="$path"
                        break
                    fi
                    ((idx++))
                done < "$temp_volumes"

                if [[ -n "$selected_path" ]] && [[ -d "$selected_path" ]]; then
                    # Save cursor for potential return
                    local saved_cursor=$cursor

                    # Don't cleanup yet - stay in alternate screen
                    trap - EXIT INT TERM

                    # Enter drill-down, check return value
                    if interactive_drill_down "$selected_path" ""; then
                        # User quit (Q/ESC) - cleanup and exit
                        cleanup_volumes
                        return 0
                    else
                        # User went back (LEFT at root) - return to menu
                        # Restore trap
                        trap cleanup_volumes EXIT INT TERM
                        cursor=$saved_cursor
                        # Just continue loop to redraw menu
                    fi
                fi
                ;;
            "LEFT")
                # In volumes view, LEFT does nothing (already at top level)
                # User must press q/ESC to quit
                ;;
            "QUIT"|"q")
                # Quit the volumes view
                break
                ;;
        esac
    done

    cleanup_volumes
    trap - EXIT INT TERM
}

# Interactive drill-down mode
interactive_drill_down() {
    local start_path="$1"
    local initial_items="${2:-}"  # Pre-scanned items for first level
    local current_path="$start_path"
    local path_stack=()
    local cursor=0
    local scroll_offset=0  # New: for scrolling
    local need_scan=true
    local wait_for_calc=false  # Don't wait on first load, let user press 'r'
    local temp_items="$TEMP_PREFIX.items"
    local status_message=""

    # Cache variables to avoid recalculation
    local -a items=()
    local has_calculating=false
    local total_items=0

    # Directory cache: store scan results for each visited directory
    # Use temp files because bash 3.2 doesn't have associative arrays
    local cache_dir="$TEMP_PREFIX.cache.$$"
    mkdir -p "$cache_dir" 2>/dev/null || true

    # Note: We're already in alternate screen from show_volumes_overview
    # Just hide cursor, don't re-enter alternate screen
    printf "\033[?25l"  # Hide cursor

    # Save terminal settings and disable echo
    local old_tty_settings=""
    if [[ -t 0 ]]; then
        old_tty_settings=$(stty -g 2>/dev/null || echo "")
        stty -echo 2>/dev/null || true
    fi

    # Cleanup on exit (but don't exit alternate screen - may return to menu)
    cleanup_drill_down() {
        # Restore terminal settings
        if [[ -n "${old_tty_settings:-}" ]]; then
            stty "$old_tty_settings" 2>/dev/null || true
        fi
        printf "\033[?25h"  # Show cursor
        # Don't call tput rmcup - we may be returning to volumes menu
        [[ -d "${cache_dir:-}" ]] && rm -rf "$cache_dir" 2>/dev/null || true  # Clean up cache
    }
    trap cleanup_drill_down EXIT INT TERM

    # Drain any input that accumulated before entering interactive mode
    type drain_pending_input >/dev/null 2>&1 && drain_pending_input

    while true; do
        # Ensure cursor is always hidden during navigation
        printf "\033[?25l" >&2

        # Only scan if needed (directory changed or refresh requested)
        if [[ "$need_scan" == "true" ]]; then
            # Generate cache key (use md5 hash of path)
            local cache_key=$(echo "$current_path" | md5 2>/dev/null || echo "$current_path" | shasum | cut -d' ' -f1)
            local cache_file="$cache_dir/$cache_key"

            # Check if we have cached results for this directory
            if [[ -f "$cache_file" ]] && [[ "$wait_for_calc" != "true" ]]; then
                # Load from cache (instant!)
                cp "$cache_file" "$temp_items"
            else
                # Fast scan: load more items for scrolling (top 50)
                # Note: scan function will handle screen clearing and progress display
                # Use || true to prevent exit on scan failure
                scan_directory_contents_fast "$current_path" "$temp_items" 50 true || {
                    # Scan failed - create empty result file
                    > "$temp_items"
                }

                # Save to cache for next time (only if not empty)
                if [[ -s "$temp_items" ]]; then
                    cp "$temp_items" "$cache_file" 2>/dev/null || true
                fi
            fi

            # Load items into array
            items=()
            if [[ -f "$temp_items" ]] && [[ -s "$temp_items" ]]; then
                while IFS='|' read -r size type path; do
                    items+=("$size|$type|$path")
                done < "$temp_items"
            fi
            total_items=${#items[@]}

            # No more calculating state
            has_calculating=false
            need_scan=false
            wait_for_calc=false

            # Reset scroll when entering new directory
            scroll_offset=0

            # Drain any input accumulated during scanning
            type drain_pending_input >/dev/null 2>&1 && drain_pending_input

            # Check if empty or scan failed
            if [[ $total_items -eq 0 ]]; then
                # Check if directory actually exists and is readable
                if [[ ! -d "$current_path" ]] || [[ ! -r "$current_path" ]]; then
                    # Directory doesn't exist or can't read - show error
                    printf "\033[H\033[J" >&2
                    echo "" >&2
                    echo "  ${RED}Error: Cannot access directory${NC}" >&2
                    echo "  ${GRAY}Path: $current_path${NC}" >&2
                    echo "" >&2
                    echo "  ${GRAY}Press any key to go back...${NC}" >&2
                    read_key >/dev/null 2>&1
                else
                    # Directory exists but scan returned nothing (timeout or empty)
                    printf "\033[H\033[J" >&2
                    echo "" >&2
                    echo "  ${YELLOW}Empty directory or scan timeout${NC}" >&2
                    echo "  ${GRAY}Path: $current_path${NC}" >&2
                    echo "" >&2
                    echo "  ${GRAY}Press ${NC}${GREEN}R${NC}${GRAY} to retry, any other key to go back${NC}" >&2

                    local retry_key
                    retry_key=$(read_key 2>/dev/null || echo "OTHER")

                    if [[ "$retry_key" == "RETRY" ]]; then
                        # Retry scan
                        need_scan=true
                        continue
                    fi
                fi

                # Go back to parent
                if [[ ${#path_stack[@]} -gt 0 ]]; then
                    # Use bash 3.2 compatible way to get last element
                    local stack_size=${#path_stack[@]}
                    local last_index=$((stack_size - 1))
                    current_path="${path_stack[$last_index]}"
                    unset "path_stack[$last_index]"
                    cursor=0
                    need_scan=true
                    continue
                else
                    # Can't go back further, just stay and show empty view
                    # Add a dummy item so the interface doesn't break
                    items=("0|dir|$current_path")
                    total_items=1
                fi
            fi
        fi

        # Build output buffer once for smooth rendering
        local output=""
        output+="\033[?25l"  # Hide cursor
        output+="\033[H\033[J"  # Clear screen
        output+=$'\n'
        output+="\033[0;35mDisk space explorer > $(echo "$current_path" | sed "s|^$HOME|~|")\033[0m"$'\n'
        output+=$'\n'

        local max_show=15  # Show 15 items per page
        local page_start=$scroll_offset
        local page_end=$((scroll_offset + max_show))
        [[ $page_end -gt $total_items ]] && page_end=$total_items

        local display_idx=0
        local idx=0
        for item_info in "${items[@]}"; do
            # Skip items before current page
            if [[ $idx -lt $page_start ]]; then
                ((idx++))
                continue
            fi

            # Stop if we've shown enough items for this page
            if [[ $idx -ge $page_end ]]; then
                break
            fi

            local size="${item_info%%|*}"
            local rest="${item_info#*|}"
            local type="${rest%%|*}"
            local path="${rest#*|}"
            local name=$(basename "$path")

            local human_size
            if [[ "$size" -eq 0 ]]; then
                human_size="0B"
            else
                human_size=$(bytes_to_human "$size")
            fi

            # Determine label and color hints
            local badge="$BADGE_FILE" color="${NC}"
            if [[ "$type" == "dir" ]]; then
                badge="$BADGE_DIR" color="${BLUE}"
                if [[ $size -gt 10737418240 ]]; then color="${RED}"
                elif [[ $size -gt 1073741824 ]]; then color="${YELLOW}"
                fi
            else
                local ext="${name##*.}"
                local info=$(get_file_info "$path")
                badge="${info%|*}"
                case "$ext" in
                    dmg|iso|pkg|zip|tar|gz|rar|7z)
                        color="${YELLOW}"
                        ;;
                    mov|mp4|avi|mkv|webm|jpg|jpeg|png|gif|heic)
                        color="${YELLOW}"
                        ;;
                    log)
                        color="${GRAY}"
                        ;;
                esac
            fi

            # Truncate name
            if [[ ${#name} -gt 50 ]]; then name="${name:0:47}..."; fi

            # Build line with emoji badge, size, and name
            local line
            if [[ $idx -eq $cursor ]]; then
                line=$(printf "  ${GREEN}▶${NC} %s%s${NC} %10s    %s${NC}" "$color" "$badge" "$human_size" "$name")
            else
                line=$(printf "    %s%s${NC} %10s    %s${NC}" "$color" "$badge" "$human_size" "$name")
            fi
            output+="$line"$'\n'

            ((idx++))
            ((display_idx++))
        done

        output+=$'\n'

        # Show pagination info if there are more items
        if [[ $total_items -gt $max_show ]]; then
            local showing_end=$page_end
            output+="  ${GRAY}Showing $((page_start + 1))-$showing_end of $total_items items${NC}"$'\n'
            output+=$'\n'
        fi

        if [[ -n "$status_message" ]]; then
            output+="  $status_message"$'\n\n'
            status_message=""
        fi

        # Bottom help bar
        output+="  ${GRAY}↑/↓${NC} Navigate  ${GRAY}|${NC}  ${GRAY}Enter${NC} Open  ${GRAY}|${NC}  ${GRAY}←${NC} Back  ${GRAY}|${NC}  ${GRAY}Del${NC} Delete  ${GRAY}|${NC}  ${GRAY}O${NC} Finder  ${GRAY}|${NC}  ${GRAY}Q/ESC${NC} Quit"$'\n'

        # Output everything at once (single write = no flicker)
        printf "%b" "$output" >&2

        # Read key directly without draining (to preserve all user input)
        local key
        key=$(read_key 2>/dev/null || echo "OTHER")

        # Debug: uncomment to see what keys are being received
        # printf "\rDEBUG: Received key=[%s]     " "$key" >&2
        # sleep 1

        case "$key" in
            "UP")
                # Move cursor up
                if [[ $cursor -gt 0 ]]; then
                    ((cursor--))
                    # Scroll up if cursor goes above visible area
                    if [[ $cursor -lt $scroll_offset ]]; then
                        scroll_offset=$cursor
                    fi
                fi
                ;;
            "DOWN")
                # Move cursor down
                if [[ $cursor -lt $((total_items - 1)) ]]; then
                    ((cursor++))
                    # Scroll down if cursor goes below visible area
                    local page_end=$((scroll_offset + max_show))
                    if [[ $cursor -ge $page_end ]]; then
                        scroll_offset=$((cursor - max_show + 1))
                    fi
                fi
                ;;
            "ENTER"|"RIGHT")
                # Enter selected item - directory or file
                if [[ $cursor -lt ${#items[@]} ]]; then
                    local selected="${items[$cursor]}"
                    local size="${selected%%|*}"
                    local rest="${selected#*|}"
                    local type="${rest%%|*}"
                    local selected_path="${rest#*|}"

                    if [[ "$type" == "dir" ]]; then
                        # Push current path to stack and enter the directory
                        path_stack+=("$current_path")
                        current_path="$selected_path"
                        cursor=0
                        need_scan=true
                    else
                        # It's a file - open it for viewing
                        local file_ext="${selected_path##*.}"
                        local filename=$(basename "$selected_path")
                        local open_success=false

                        # For text-like files, use less or fallback to open
                        case "$file_ext" in
                            txt|log|md|json|xml|yaml|yml|conf|cfg|ini|sh|bash|zsh|py|js|ts|go|rs|c|cpp|h|java|rb|php|html|css|sql)
                                # Clear screen and show loading message
                                printf "\033[H\033[J"
                                echo ""
                                echo "  ${BLUE}Opening file:${NC} $filename"
                                echo ""

                                # Try less first (best for text viewing)
                                if command -v less &>/dev/null; then
                                    # Exit alternate screen only for less
                                    printf "\033[?25h"  # Show cursor
                                    tput rmcup 2>/dev/null || true

                                    less -F "$selected_path" 2>/dev/null && open_success=true

                                    # Return to alternate screen
                                    tput smcup 2>/dev/null || true
                                    printf "\033[?25l"  # Hide cursor
                                else
                                    # Fallback to system open if less is not available
                                    echo "  ${GRAY}Launching default application...${NC}"
                                    if command -v open &>/dev/null; then
                                        open "$selected_path" 2>/dev/null && open_success=true
                                        if [[ "$open_success" == "true" ]]; then
                                            echo ""
                                            echo "  ${GREEN}✓${NC} File opened in external app"
                                            sleep 0.8
                                        fi
                                    fi
                                fi
                                ;;
                            *)
                                # For other files, use system open (keep in alternate screen)
                                # Show message without flashing
                                printf "\033[H\033[J"
                                echo ""
                                echo "  ${BLUE}Opening file:${NC} $filename"
                                echo ""
                                echo "  ${GRAY}Launching default application...${NC}"

                                if command -v open &>/dev/null; then
                                    open "$selected_path" 2>/dev/null && open_success=true

                                    # Show brief success message
                                    if [[ "$open_success" == "true" ]]; then
                                        echo ""
                                        echo "  ${GREEN}✓${NC} File opened in external app"
                                        sleep 0.8
                                    fi
                                fi
                                ;;
                        esac

                        # If nothing worked, show error message
                        if [[ "$open_success" != "true" ]]; then
                            printf "\033[H\033[J"
                            echo ""
                            echo "  ${YELLOW}Warning:${NC} Could not open file"
                            echo ""
                            echo "  ${GRAY}File: $selected_path${NC}"
                            echo "  ${GRAY}Press any key to return...${NC}"
                            read -n 1 -s 2>/dev/null
                        fi
                    fi
                fi
                ;;
            "LEFT")
                # Go back to parent directory with left arrow
                if [[ ${#path_stack[@]} -gt 0 ]]; then
                    # Pop from stack and go back
                    # Use bash 3.2 compatible way to get last element
                    local stack_size=${#path_stack[@]}
                    local last_index=$((stack_size - 1))
                    current_path="${path_stack[$last_index]}"
                    unset "path_stack[$last_index]"
                    cursor=0
                    scroll_offset=0
                    need_scan=true
                else
                    # Already at start path - return to volumes menu
                    # Don't show cursor or exit screen - menu will handle it
                    if [[ -n "${old_tty_settings:-}" ]]; then
                        stty "$old_tty_settings" 2>/dev/null || true
                    fi
                    [[ -d "${cache_dir:-}" ]] && rm -rf "$cache_dir" 2>/dev/null || true
                    trap - EXIT INT TERM
                    return 1  # Return to menu
                fi
                ;;
            "OPEN")
                if command -v open >/dev/null 2>&1; then
                    if open "$current_path" >/dev/null 2>&1; then
                        status_message="${GREEN}✓${NC} Finder opened: ${GRAY}$current_path${NC}"
                    else
                        status_message="${YELLOW}Warning:${NC} Could not open ${GRAY}$current_path${NC}"
                    fi
                else
                    status_message="${YELLOW}Warning:${NC} 'open' command not available"
                fi
                ;;
            "DELETE")
                # Delete selected item (file or directory)
                if [[ $cursor -lt ${#items[@]} ]]; then
                    local selected="${items[$cursor]}"
                    local size="${selected%%|*}"
                    local rest="${selected#*|}"
                    local type="${rest%%|*}"
                    local selected_path="${rest#*|}"
                    local selected_name=$(basename "$selected_path")
                    local human_size=$(bytes_to_human "$size")

                    # Check if sudo is needed
                    local needs_sudo=false
                    if [[ ! -w "$selected_path" ]] || [[ ! -w "$(dirname "$selected_path")" ]]; then
                        needs_sudo=true
                    fi

                    # Build simple confirmation
                    printf "\033[H\033[J"
                    echo ""
                    echo ""

                    if [[ "$type" == "dir" ]]; then
                        echo "  ${RED}Delete folder? ${YELLOW}Warning:${NC} This action cannot be undone!"
                    else
                        echo "  ${RED}Delete file? ${YELLOW}Warning:${NC} This action cannot be undone!"
                    fi

                    echo ""

                    # Show icon based on type
                    if [[ "$type" == "dir" ]]; then
                        echo "  ${BADGE_DIR} ${YELLOW}$selected_name${NC}"
                    else
                        local info=$(get_file_info "$selected_path")
                        local badge="${info%|*}"
                        echo "  $badge ${YELLOW}$selected_name${NC}"
                    fi

                    echo "  ${GRAY}Size: $human_size${NC}"
                    echo "  ${GRAY}Path: $selected_path${NC}"

                    if [[ "$needs_sudo" == "true" ]]; then
                        echo ""
                        echo "  ${YELLOW}Warning:${NC} Requires admin privileges"
                    fi

                    echo ""
                    echo "  ${GRAY}Press ${NC}${GREEN}ENTER${NC}${GRAY} to confirm, ${NC}${YELLOW}ESC/Q${NC}${GRAY} to cancel${NC}"

                    # Read confirmation
                    local confirm
                    confirm=$(read_key 2>/dev/null || echo "QUIT")

                    if [[ "$confirm" == "ENTER" ]]; then
                        # Request sudo if needed before deletion
                        if [[ "$needs_sudo" == "true" ]]; then
                            printf "\033[H\033[J"
                            echo ""
                            echo ""
                            if ! request_sudo_access "Admin access required to delete this item"; then
                                echo ""
                                echo "  ${RED}✗ Admin access denied${NC}"
                                sleep 1.5
                                continue
                            fi
                        fi

                        # Show deleting message
                        printf "\033[H\033[J"
                        echo ""
                        echo "  ${BLUE}Deleting...${NC}"
                        echo ""

                        # Try to delete with sudo if needed
                        local delete_success=false
                        if [[ "$needs_sudo" == "true" ]]; then
                            if sudo rm -rf "$selected_path" 2>/dev/null; then
                                delete_success=true
                            fi
                        else
                            if rm -rf "$selected_path" 2>/dev/null; then
                                delete_success=true
                            fi
                        fi

                        if [[ "$delete_success" == "true" ]]; then
                            echo "  ${GREEN}✓ Deleted successfully${NC}"
                            echo "  ${GRAY}Freed: $human_size${NC}"
                            sleep 0.8

                            # Clear cache to force rescan
                            local cache_key=$(echo "$current_path" | md5 2>/dev/null || echo "$current_path" | shasum | cut -d' ' -f1)
                            local cache_file="$cache_dir/$cache_key"
                            rm -f "$cache_file" 2>/dev/null || true

                            # Refresh the view
                            need_scan=true

                            # Adjust cursor if needed
                            if [[ $cursor -ge $((total_items - 1)) ]] && [[ $cursor -gt 0 ]]; then
                                ((cursor--))
                            fi
                        else
                            echo "  ${RED}✗ Failed to delete${NC}"
                            echo ""
                            echo "  ${YELLOW}Possible reasons:${NC}"
                            echo "  • File is being used by another application"
                            echo "  • Insufficient permissions"
                            echo "  • System protection (SIP) prevents deletion"
                            echo ""
                            echo "  ${GRAY}Press any key to continue...${NC}"
                            read_key >/dev/null 2>&1
                        fi
                    fi
                fi
                ;;
            "QUIT"|"q")
                # Quit the explorer
                cleanup_drill_down
                trap - EXIT INT TERM
                return 0  # Return true to indicate normal exit
                ;;
            *)
                # Unknown key - ignore it
                ;;
        esac
    done

    # Cleanup is handled by trap
    return 0  # Normal exit if loop ends
}

# Main interactive loop
interactive_mode() {
    CURSOR_POS=0
    VIEW_MODE="overview"

    while true; do
        type drain_pending_input >/dev/null 2>&1 && drain_pending_input
        display_interactive_menu

        local key=$(read_key)
        case "$key" in
            "QUIT")
                break
                ;;
            "UP")
                if [[ "$VIEW_MODE" == "navigate" ]]; then
                    ((CURSOR_POS > 0)) && ((CURSOR_POS--))
                fi
                ;;
            "DOWN")
                if [[ "$VIEW_MODE" == "navigate" ]]; then
                    local max_count=$(count_directories)
                    ((CURSOR_POS < max_count - 1)) && ((CURSOR_POS++))
                fi
                ;;
            "RIGHT")
                if [[ "$VIEW_MODE" == "navigate" ]]; then
                    # Enter selected directory
                    local selected_path=$(get_path_at_cursor "$CURSOR_POS")
                    if [[ -n "$selected_path" ]] && [[ -d "$selected_path" ]]; then
                        CURRENT_PATH="$selected_path"
                        CURSOR_POS=0
                        perform_scan "$CURRENT_PATH"
                    fi
                else
                    # Enter navigation mode
                    VIEW_MODE="navigate"
                    CURSOR_POS=0
                fi
                ;;
            "LEFT")
                if [[ "$VIEW_MODE" == "navigate" ]]; then
                    # Go back to parent
                    if [[ "$CURRENT_PATH" != "$HOME" ]] && [[ "$CURRENT_PATH" != "/" ]]; then
                        CURRENT_PATH="$(dirname "$CURRENT_PATH")"
                        CURSOR_POS=0
                        perform_scan "$CURRENT_PATH"
                    fi
                else
                    VIEW_MODE="overview"
                fi
                ;;
            "f"|"F")
                VIEW_MODE="files"
                ;;
            "t"|"T")
                VIEW_MODE="types"
                ;;
            "ENTER")
                if [[ "$VIEW_MODE" == "navigate" ]]; then
                    # Same as RIGHT
                    local selected_path=$(get_path_at_cursor "$CURSOR_POS")
                    if [[ -n "$selected_path" ]] && [[ -d "$selected_path" ]]; then
                        CURRENT_PATH="$selected_path"
                        CURSOR_POS=0
                        perform_scan "$CURRENT_PATH"
                    fi
                else
                    break
                fi
                ;;
            *)
                # Any other key in overview mode exits
                if [[ "$VIEW_MODE" == "overview" ]]; then
                    break
                fi
                ;;
        esac
    done
}

# ============================================================================
# Main Entry Point
# ============================================================================

# Export results to CSV
export_to_csv() {
    local output_file="$1"
    local temp_dirs="$TEMP_PREFIX.dirs"

    if [[ ! -f "$temp_dirs" ]]; then
        log_error "No scan data available to export"
        return 1
    fi

    {
        echo "Size (Bytes),Size (Human),Path"
        while IFS='|' read -r size path; do
            local human=$(bytes_to_human "$size")
            echo "$size,\"$human\",\"$path\""
        done < "$temp_dirs"
    } > "$output_file"

    log_success "Exported to $output_file"
}

# Export results to JSON
export_to_json() {
    local output_file="$1"
    local temp_dirs="$TEMP_PREFIX.dirs"
    local temp_large="$TEMP_PREFIX.large"

    if [[ ! -f "$temp_dirs" ]]; then
        log_error "No scan data available to export"
        return 1
    fi

    {
        echo "{"
        echo "  \"scan_date\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
        echo "  \"target_path\": \"$CURRENT_PATH\","
        echo "  \"directories\": ["

        local first=true
        while IFS='|' read -r size path; do
            [[ "$first" == "false" ]] && echo ","
            first=false
            local human=$(bytes_to_human "$size")
            printf '    {"size": %d, "size_human": "%s", "path": "%s"}' "$size" "$human" "$path"
        done < "$temp_dirs"

        echo ""
        echo "  ],"
        echo "  \"large_files\": ["

        if [[ -f "$temp_large" ]]; then
            first=true
            while IFS='|' read -r size path; do
                [[ "$first" == "false" ]] && echo ","
                first=false
                local human=$(bytes_to_human "$size")
                printf '    {"size": %d, "size_human": "%s", "path": "%s"}' "$size" "$human" "$path"
            done < "$temp_large"
            echo ""
        fi

        echo "  ]"
        echo "}"
    } > "$output_file"

    log_success "Exported to $output_file"
}

main() {
    local target_path="$HOME"

    # Parse arguments - only support --help
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                echo "Usage: mole analyze"
                echo ""
                echo "Interactive disk space explorer - Navigate folders sorted by size"
                echo ""
                echo "Keyboard Controls:"
                echo "  ↑/↓         Navigate items"
                echo "  Enter / →   Open selected folder"
                echo "  ←           Go back to parent directory"
                echo "  Delete      Delete selected file/folder (requires confirmation)"
                echo "  O           Reveal current directory in Finder"
                echo "  Q / ESC     Quit the explorer"
                echo ""
                echo "Features:"
                echo "  • Files and folders sorted by size (largest first)"
                echo "  • Shows top 16 items per directory"
                echo "  • Fast parallel scanning with smart timeout"
                echo "  • Session cache for instant navigation"
                echo "  • Color coding for large folders (Red >10GB, Yellow >1GB)"
                echo "  • Safe deletion with confirmation"
                echo ""
                echo "Examples:"
                echo "  mole analyze           Start exploring from home directory"
                echo ""
                exit 0
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                echo "Usage: mole analyze" >&2
                echo "Use 'mole analyze --help' for more information" >&2
                exit 1
                ;;
            *)
                echo "Error: Paths are not supported in beta version" >&2
                echo "Usage: mole analyze" >&2
                echo "The explorer will start from your home directory" >&2
                exit 1
                ;;
        esac
    done

    CURRENT_PATH="$target_path"

    # Create cache directory
    mkdir -p "$CACHE_DIR" 2>/dev/null || true

    # Start with volumes overview to let user choose location
    show_volumes_overview
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
