#!/bin/bash
# Mole CLI (Linux) - system: a read-only report of what optimize does not
# cover: restart needed, installed kernels, broken packages, pending updates,
# journal size and crash reports. (Failed services, autoremove and leftover
# configuration are optimize's.) Mole changes none of it: each finding names
# the command that would, so the package manager keeps its own confirmation.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
mole_refuse_root

SYSTEM_JSON=false
for arg in "$@"; do
    case "$arg" in
        --json) SYSTEM_JSON=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            echo "Usage: mo system [OPTIONS]"
            echo ""
            echo "Report what needs attention: restart, kernels, broken packages, updates,"
            echo "journal size and crash reports."
            echo "Read-only; each finding shows the command that acts on it."
            echo ""
            echo "Options:"
            echo "  --json            Output the report as JSON"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Use 'mo system --help' for supported options." >&2
            exit 1
            ;;
    esac
done

# Overridden by the tests; never read from the environment.
SYSTEM_REBOOT_FILE=/run/reboot-required
SYSTEM_CRASH_DIR=/var/crash
SYSTEM_MODULES_DIR=/usr/lib/modules

# One finding per check, in parallel arrays. STATE is attention, ok, info or
# unknown; ITEMS holds one entry per line.
CHECK_ID=()
CHECK_STATE=()
CHECK_TITLE=()
CHECK_SUMMARY=()
CHECK_COMMAND=()
CHECK_ITEMS=()

add_check() {
    CHECK_ID+=("$1")
    CHECK_STATE+=("$2")
    CHECK_TITLE+=("$3")
    CHECK_SUMMARY+=("$4")
    CHECK_COMMAND+=("${5:-}")
    CHECK_ITEMS+=("${6:-}")
}

check_restart() {
    local pkgs=""
    if [[ -e "$SYSTEM_REBOOT_FILE" ]]; then
        [[ -r "$SYSTEM_REBOOT_FILE.pkgs" ]] && pkgs=$(sort -u -- "$SYSTEM_REBOOT_FILE.pkgs")
        add_check restart attention "Restart" "Required; updates finish installing after a restart" "systemctl reboot" "$pkgs"
        return
    fi
    # Arch and others replace the running kernel's modules on upgrade.
    local running
    running=$(uname -r)
    if [[ -d "$SYSTEM_MODULES_DIR" && ! -d "$SYSTEM_MODULES_DIR/$running" ]]; then
        add_check restart attention "Restart" "Required; kernel $running was replaced; new devices may not load drivers" "systemctl reboot"
        return
    fi
    add_check restart ok "Restart" "Not needed"
}

check_apt() {
    local running pkg status kb items="" n=0 total=0
    running=$(uname -r)
    # shellcheck disable=SC2016 # dpkg-query's format fields, not shell expansions.
    while IFS=$'\t' read -r status pkg kb; do
        [[ "$status" == ii* ]] || continue
        items+="${items:+$'\n'}${pkg#linux-image-}$([[ "${pkg#linux-image-}" == "$running" ]] && echo " (running)")"
        n=$((n + 1))
        total=$((total + ${kb:-0}))
    done < <(mole_c dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\t${Installed-Size}\n' 'linux-image-[0-9]*' 2> /dev/null)
    # Which old kernels apt would remove is optimize's autoremove report;
    # this only lists what is installed.
    ((n > 0)) && add_check kernels info "Kernels" "$n installed, $(bytes_to_human_kb "$total"), running $running" "" "$items"

    local audit
    audit=$(mole_c timeout 20 dpkg --audit 2> /dev/null) || true
    if [[ -n "$audit" ]]; then
        add_check broken-packages attention "Broken packages" "dpkg reports unfinished or broken packages" \
            "sudo dpkg --configure -a" "$(grep -E '^ [a-z0-9]' <<< "$audit" | awk '{print $1}' || true)"
    else
        add_check broken-packages ok "Broken packages" "None"
    fi

    local upgradable="" nu=0 line
    while IFS= read -r line; do
        [[ "$line" == */*\[upgradable* ]] || continue
        upgradable+="${upgradable:+$'\n'}${line%%/*}"
        nu=$((nu + 1))
    done < <(mole_c timeout 20 apt list --upgradable 2> /dev/null)
    if ((nu > 0)); then
        add_check updates info "Updates" "$(mole_count_label "$nu" package) can be upgraded" \
            "sudo apt update && sudo apt upgrade" "$upgradable"
    else
        add_check updates ok "Updates" "Up to date as of the last apt update"
    fi
}

check_journal() {
    local out size
    out=$(mole_c timeout 10 journalctl --disk-usage 2> /dev/null) || return 0
    size=$(sed -n 's/.*take up \([0-9.]*[KMGT]\?\).*/\1/p' <<< "$out")
    [[ -n "$size" ]] || return 0
    [[ "$size" == *[KMGT] ]] && size+="B"
    add_check journal info "Journal" "$size on disk"
}

check_crash() {
    [[ -d "$SYSTEM_CRASH_DIR" ]] || return 0
    local f items="" n=0 kb=0
    for f in "$SYSTEM_CRASH_DIR"/*.crash; do
        [[ -f "$f" ]] || continue
        items+="${items:+$'\n'}${f##*/}"
        n=$((n + 1))
        kb=$((kb + $(mole_path_kb "$f")))
    done
    if ((n > 0)); then
        add_check crash-reports info "Crash reports" \
            "$(mole_count_label "$n" report), $(bytes_to_human_kb "$kb")" \
            "ls -l $SYSTEM_CRASH_DIR" "$items"
    else
        add_check crash-reports ok "Crash reports" "None"
    fi
}

print_text() {
    local i icon item n=0
    echo -e "${PURPLE_BOLD}System Report${NC}"
    echo ""
    for i in "${!CHECK_ID[@]}"; do
        case "${CHECK_STATE[i]}" in
            attention)
                icon="${YELLOW}${ICON_REVIEW}${NC}"
                n=$((n + 1))
                ;;
            ok) icon="${GREEN}${ICON_SUCCESS}${NC}" ;;
            *) icon="${GRAY}${ICON_EMPTY}${NC}" ;;
        esac
        echo -e "  $icon ${CHECK_TITLE[i]} · ${CHECK_SUMMARY[i]}"
        if [[ "${CHECK_STATE[i]}" != ok && -n "${CHECK_ITEMS[i]}" ]]; then
            local shown=0 total
            total=$(grep -c . <<< "${CHECK_ITEMS[i]}" || true)
            while IFS= read -r item; do
                [[ -n "$item" ]] || continue
                ((shown < 5)) || break
                echo -e "      ${GRAY}${ICON_SUBLIST} $item${NC}"
                shown=$((shown + 1))
            done <<< "${CHECK_ITEMS[i]}"
            ((total > shown)) && echo -e "      ${GRAY}${ICON_SUBLIST} and $((total - shown)) more${NC}"
        fi
        if [[ "${CHECK_STATE[i]}" == attention && -n "${CHECK_COMMAND[i]}" ]]; then
            echo -e "      ${GRAY}Run:${NC} ${CHECK_COMMAND[i]}"
        fi
    done
    if ((n == 0)); then
        print_summary_block "Nothing needs attention"
    else
        print_summary_block "$(mole_count_label "$n" item) need attention" "Mole changed nothing; run the commands above to act."
    fi
}

print_json() {
    local i sep="" item isep
    printf '{\n  "checks": ['
    for i in "${!CHECK_ID[@]}"; do
        printf '%s\n    {"id": %s, "state": %s, "title": %s, "summary": %s, "command": %s, "items": [' "$sep" \
            "$(json_string "${CHECK_ID[i]}")" "$(json_string "${CHECK_STATE[i]}")" "$(json_string "${CHECK_TITLE[i]}")" \
            "$(json_string "${CHECK_SUMMARY[i]}")" "$(json_string "${CHECK_COMMAND[i]}")"
        isep=""
        while IFS= read -r item; do
            [[ -n "$item" ]] || continue
            printf '%s%s' "$isep" "$(json_string "$item")"
            isep=", "
        done <<< "${CHECK_ITEMS[i]}"
        printf ']}'
        sep=","
    done
    printf '\n  ]\n}\n'
}

main() {
    [[ "$SYSTEM_JSON" == true ]] || start_inline_spinner "Checking system..."
    check_restart
    if command -v apt-get > /dev/null 2>&1 && command -v dpkg-query > /dev/null 2>&1; then
        check_apt
    fi
    check_journal
    check_crash
    [[ "$SYSTEM_JSON" == true ]] || stop_inline_spinner
    if [[ "$SYSTEM_JSON" == true ]]; then
        print_json
    else
        print_text
    fi
}

# Sourced by the bats tests for its functions; run directly otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
