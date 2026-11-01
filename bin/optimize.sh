#!/bin/bash
# Mole CLI (Linux) - optimize: refresh the user's font and launcher caches,
# compact browser databases while the browser is closed, and report what a
# person should act on (failed services, broken launchers and autostart
# entries, orphan packages, a stale pacman lock, TRIM, power-manager
# conflicts). It never uses sudo and never changes CPU, power or sysctl
# settings, which belong to TLP, power-profiles-daemon and the like.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/uninstall/inventory.sh"
source "$SCRIPT_DIR/lib/optimize/tasks.sh"
mole_refuse_root

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run | -n) DRY_RUN=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            echo "Usage: mo optimize [OPTIONS]"
            echo ""
            echo "Refresh caches and services, and point out what needs your attention."
            echo ""
            echo "Options:"
            echo "  --dry-run, -n     Preview optimization without making changes"
            echo "  --debug           Show detailed operation logs"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Use 'mo optimize --help' for supported options." >&2
            exit 1
            ;;
    esac
done
export DRY_RUN

trap 'stop_inline_spinner; show_cursor; echo ""; exit 130' INT TERM

# "⚙ System  6/16 GB RAM | 120/480 GB Disk | Uptime 3d", as on macOS.
show_system_line() {
    local mem_total mem_avail disk_total disk_used up
    mem_total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2> /dev/null || echo 0)
    mem_avail=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2> /dev/null || echo 0)
    read -r disk_total disk_used < <(df -kP / 2> /dev/null | awk 'NR == 2 { print $2, $3 }') || true
    up=$(awk '{ print $1 }' /proc/uptime 2> /dev/null || echo 0)
    awk -v mt="${mem_total:-0}" -v ma="${mem_avail:-0}" -v dt="${disk_total:-0}" -v du="${disk_used:-0}" -v up="${up:-0}" 'BEGIN {
        g = 1048576
        printf "%.0f/%.0f GB RAM | %.0f/%.0f GB Disk | Uptime %dd\n", (mt - ma) / g, mt / g, du / g, dt / g, up / 86400
    }' | while IFS= read -r line; do echo -e "${ICON_ADMIN} System  $line"; done
}

# "some avg60" from /proc/pressure: the share of the last minute in which at
# least one task waited for that resource.
pressure_avg60() {
    awk '/^some/ { for (i = 1; i <= NF; i++) if ($i ~ /^avg60=/) { sub(/avg60=/, "", $i); printf "%.0f", $i } }' "/proc/pressure/$1" 2> /dev/null
}

# The three busiest processes right now, from top's second sample (the first
# one averages since boot). top runs with no config of the user's, whose
# toprc could reorder or rename the columns; a command name may hold spaces.
busiest_processes() {
    command -v top > /dev/null 2>&1 || return 0
    local cfg
    cfg=$(mktemp -d 2> /dev/null) || return 0
    HOME="$cfg" XDG_CONFIG_HOME="$cfg" LC_ALL=C top -b -n 2 -d 0.5 -w 512 -o %CPU 2> /dev/null | awk '
        /^ *PID / { frame++; next }
        frame == 2 && NF >= 12 && $9 + 0 > 0 {
            name = $12; for (i = 13; i <= NF; i++) name = name " " $i
            printf "%s %.0f%%\n", name, $9; if (++n == 3) exit
        }
    ' | paste -sd ',' - | sed 's/,/, /g' || true
    rmdir "$cfg" 2> /dev/null || true
}

show_diagnosis() {
    echo ""
    echo -e "${BLUE}Performance diagnosis${NC}"
    if [[ ! -r /proc/pressure/cpu ]]; then
        echo -e "  ${GRAY}${ICON_EMPTY} Pressure stats are not available on this kernel${NC}"
        return
    fi
    local cpu mem io found=false top
    cpu=$(pressure_avg60 cpu) || cpu=0
    mem=$(pressure_avg60 memory) || mem=0
    io=$(pressure_avg60 io) || io=0
    if ((${cpu:-0} >= 25)); then
        top=$(busiest_processes) || top=""
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} CPU was busy ${cpu}% of the last minute${top:+, busiest: $top}"
        found=true
    fi
    if ((${mem:-0} >= 10)); then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Memory ran short ${mem}% of the last minute, apps waited while the kernel freed or swapped pages"
        found=true
    fi
    if ((${io:-0} >= 25)); then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Disk was a bottleneck ${io}% of the last minute"
        found=true
    fi
    [[ "$found" == true ]] || echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No sustained CPU, memory or disk pressure"
}

FIRST_ACTION=true
run_task() {
    local name="$1" fn="$2" before
    if [[ "$FIRST_ACTION" == true ]]; then
        FIRST_ACTION=false
    else
        echo ""
    fi
    echo -e "${BLUE}${ICON_ARROW} ${name}${NC}"
    _OPT_CURRENT="$name"
    before=${#OPT_TASK_OUTCOMES[@]}
    "$fn" || true
    # Every task records exactly one outcome; a task that did not is a bug.
    if ((${#OPT_TASK_OUTCOMES[@]} != before + 1)); then
        OPT_TASK_NAMES=("${OPT_TASK_NAMES[@]:0:before}" "$name")
        OPT_TASK_OUTCOMES=("${OPT_TASK_OUTCOMES[@]:0:before}" failed)
    fi
}

show_summary() {
    local applied unchanged skipped unavailable attention failed
    applied=$(opt_count applied)
    unchanged=$(opt_count unchanged)
    skipped=$(opt_count skipped)
    unavailable=$(opt_count unavailable)
    attention=$(opt_count attention)
    failed=$(opt_count failed)
    local -a parts=() details=()
    ((unchanged > 0)) && parts+=("$unchanged unchanged")
    ((skipped > 0)) && parts+=("$skipped skipped")
    ((unavailable > 0)) && parts+=("$unavailable unavailable")
    ((attention > 0)) && parts+=("$attention $(opt_agree "$attention" needs need) attention")
    ((failed > 0)) && parts+=("$failed failed")
    local line="" p
    for p in "${parts[@]}"; do
        line+="${line:+ | }$p"
    done
    if [[ "$DRY_RUN" == "true" ]]; then
        details+=("Would apply ${YELLOW}${applied}${NC} $(opt_agree "$applied" optimization optimizations)")
        [[ -n "$line" ]] && details+=("$line")
        details+=("Run without ${YELLOW}--dry-run${NC} to apply these changes")
        print_summary_block "Dry Run Complete, No Changes Made" "${details[@]}"
    else
        local stat=""
        ((OPT_RECLAIMED_BYTES > 0)) && stat=", $(bytes_to_human "$OPT_RECLAIMED_BYTES") reclaimed"
        details+=("Applied ${GREEN}${applied}${NC} $(opt_agree "$applied" optimization optimizations)${stat}")
        [[ -n "$line" ]] && details+=("$line")
        if ((attention > 0 || failed > 0)); then
            details+=("Review the warnings above")
        else
            details+=("Optimization pass complete")
        fi
        print_summary_block "Optimization Complete" "${details[@]}"
    fi
}

main() {
    echo -e "${PURPLE_BOLD}Optimize${NC}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} DRY RUN MODE${NC}, No files will be modified"
    fi
    echo ""
    show_system_line
    show_diagnosis
    echo ""

    run_task "Font Cache Refresh" task_fonts
    run_task "App Launchers" task_launchers
    run_task "Autostart Entries" task_autostart
    run_task "Failed Services" task_services
    if command -v pacman > /dev/null 2>&1; then
        run_task "Orphan Packages" task_orphans
        run_task "Package Database Lock" task_pacman_lock
    fi
    run_task "Browser Databases" task_browser_dbs
    run_task "Disk TRIM" task_trim
    run_task "Power Management" task_power

    show_summary
    echo ""
    local i
    for i in "${!OPT_TASK_OUTCOMES[@]}"; do
        [[ "${OPT_TASK_OUTCOMES[i]}" == failed ]] && log_operation optimize TASK_FAILED "${OPT_TASK_NAMES[i]}" "task outcome"
    done
    [[ "$(opt_count failed)" -eq 0 ]]
}

main
