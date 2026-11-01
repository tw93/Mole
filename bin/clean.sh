#!/bin/bash
# Mole CLI (Linux) - clean: remove regenerable caches from an allowlist, empty
# the Trash, and trim the package cache and journal through their own tools.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/clean/rules.sh"
mole_refuse_root

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run | -n) DRY_RUN=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            echo "Usage: mo clean [OPTIONS]"
            echo ""
            echo "Remove caches that apps rebuild by themselves, empty the Trash, and trim"
            echo "old package files and journal logs through pacman's and systemd's own tools."
            echo ""
            echo "Options:"
            echo "  --dry-run, -n     Preview cleanup without making changes"
            echo "  --debug           Show detailed operation logs"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Use 'mo clean --help' for supported options." >&2
            exit 1
            ;;
    esac
done
export DRY_RUN

TOTAL_KB=0
TOTAL_ITEMS=0
SYSTEM_READY=false

trap 'stop_inline_spinner; show_cursor; echo ""; exit 130' INT TERM

report_line() {
    local label="$1" kb="$2" count="$3" note="${4:-}"
    local size count_note=""
    stop_section_spinner
    size=$(bytes_to_human_kb "$kb")
    [[ "$count" -gt 1 ]] && count_note="$(mole_count_label "$count" item), "
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $label · ${count_note}$(colorize_human_size "$size")${note} ${YELLOW}dry${NC}"
    else
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $label · ${count_note}$(colorize_human_size "$size")${note}"
    fi
    note_activity
}

skip_line() {
    stop_section_spinner
    echo -e "  ${GRAY}${ICON_EMPTY} $1${NC}"
    note_activity
}

add_total() {
    TOTAL_KB=$((TOTAL_KB + $1))
    TOTAL_ITEMS=$((TOTAL_ITEMS + $2))
}

# Remove every child of one allowlisted root; the root itself stays.
clean_rule() {
    local label="$1" root="$2" owners="$3"
    [[ -n "$root" && -d "$root" && ! -L "$root" ]] || return 0
    local -a children=()
    local child
    while IFS= read -r -d '' child; do
        children+=("$child")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2> /dev/null)
    [[ ${#children[@]} -gt 0 ]] || return 0

    local kb
    kb=$(mole_path_kb "$root")
    ((kb >= 8)) || return 0

    # An owner that runs, or a probe that cannot tell, skips the rule.
    if [[ "$owners" == flatpak:* ]]; then
        local rc=0
        mole_flatpak_running "${owners#flatpak:}" || rc=$?
        if [[ $rc -ne 1 ]]; then
            skip_line "$label · skipped while ${owners#flatpak:} is running"
            return 0
        fi
    elif [[ -n "$owners" ]]; then
        local -a names=()
        IFS=',' read -ra names <<< "$owners"
        local rc=0
        mole_process_running "${names[@]}" || rc=$?
        if [[ $rc -ne 1 ]]; then
            skip_line "$label · skipped while ${names[0]} is running"
            return 0
        fi
    fi

    local removed=0 failed=0
    for child in "${children[@]}"; do
        if mole_remove_cache "$child" "$root" clean "$label"; then
            removed=$((removed + 1))
        else
            failed=$((failed + 1))
        fi
    done
    if [[ "$DRY_RUN" != "true" ]]; then
        local left
        left=$(mole_path_kb "$root")
        kb=$((kb > left ? kb - left : 0))
    fi
    if ((removed > 0 && kb > 0)); then
        report_line "$label" "$kb" "$removed"
        add_total "$kb" "$removed"
    fi
    ((failed > 0)) && debug_log "$label: $failed item(s) not removed"
    return 0
}

clean_user_rules() {
    local current="" section label root owners
    while IFS='|' read -r section label root owners; do
        [[ -n "$section" ]] || continue
        if [[ "$section" != "$current" ]]; then
            if [[ -n "$current" ]]; then
                stop_section_spinner
                end_section
            fi
            current="$section"
            start_section "$section"
        fi
        start_section_spinner "Scanning $label..."
        clean_rule "$label" "$root" "$owners"
    done < <(mole_clean_rules)
    stop_section_spinner
    [[ -n "$current" ]] && end_section
    return 0
}

clean_trash() {
    start_section "Trash"
    local files="$MOLE_TRASH_DIR/files" info="$MOLE_TRASH_DIR/info"
    if [[ ! -d "$files" || -L "$files" ]]; then
        end_section
        return 0
    fi
    local -a entries=()
    local e
    while IFS= read -r -d '' e; do entries+=("$e"); done < <(find "$files" -mindepth 1 -maxdepth 1 -print0 2> /dev/null)
    if [[ ${#entries[@]} -eq 0 ]]; then
        end_section
        return 0
    fi
    local kb removed=0 meta
    kb=$(mole_path_kb "$files")
    for e in "${entries[@]}"; do
        if mole_remove_cache "$e" "$files" clean "Trash"; then
            removed=$((removed + 1))
            meta="$info/$(basename -- "$e").trashinfo"
            [[ -f "$meta" ]] && mole_remove_cache "$meta" "$info" clean "Trash info" || true
        fi
    done
    if [[ "$DRY_RUN" != "true" ]]; then
        local left
        left=$(mole_path_kb "$files")
        kb=$((kb > left ? kb - left : 0))
    fi
    if ((removed > 0)); then
        report_line "Trash" "$kb" "$removed"
        add_total "$kb" "$removed"
    fi
    end_section
}

# "421.20 MiB" / "225.0M" -> KB
human_to_kb() {
    awk -v v="$1" 'BEGIN {
        n = v + 0; u = v; sub(/^[0-9.]+ */, "", u); u = toupper(substr(u, 1, 1))
        m = 1 / 1024
        if (u == "K") m = 1; else if (u == "M") m = 1024; else if (u == "G") m = 1048576; else if (u == "T") m = 1073741824
        printf "%d", n * m
    }'
}

journal_usage_kb() {
    local usage
    usage=$(mole_c journalctl --disk-usage 2> /dev/null | grep -oE 'take up [0-9.]+[KMGT]?' | awk '{print $3}') || usage=""
    human_to_kb "${usage:-0}"
}

clean_system() {
    local have_paccache=false have_journal=false
    command -v paccache > /dev/null 2>&1 && [[ -d /var/cache/pacman/pkg ]] && have_paccache=true
    command -v journalctl > /dev/null 2>&1 && have_journal=true
    [[ "$have_paccache" == "true" || "$have_journal" == "true" ]] || return 0

    start_section "System"
    if [[ "$DRY_RUN" != "true" ]]; then
        if mole_sudo_ready "Package cache and journal trimming need sudo"; then
            SYSTEM_READY=true
        else
            skip_line "Package cache and journal · skipped without sudo"
            end_section
            return 0
        fi
    fi

    if [[ "$have_paccache" == "true" ]]; then
        if [[ -e /var/lib/pacman/db.lck ]]; then
            skip_line "Package cache · skipped while pacman is running"
        else
            local out kb=0 count=0
            out=$(mole_c paccache -dk2 2> /dev/null | tail -1) || out=""
            if [[ "$out" =~ ([0-9]+)\ candidate.*saved:\ ([0-9.]+\ [KMGT]i?B) ]]; then
                count="${BASH_REMATCH[1]}"
                kb=$(human_to_kb "${BASH_REMATCH[2]}")
            fi
            if ((count > 0)); then
                if [[ "$DRY_RUN" == "true" ]]; then
                    report_line "Package cache, older versions" "$kb" "$count" " ${GRAY}(keeps 2)${NC}"
                    add_total "$kb" "$count"
                elif mole_c sudo paccache -rk2 > /dev/null 2>&1; then
                    report_line "Package cache, older versions" "$kb" "$count" " ${GRAY}(keeps 2)${NC}"
                    log_operation clean REMOVED /var/cache/pacman/pkg "paccache -rk2, $count files"
                    add_total "$kb" "$count"
                else
                    log_error "paccache -rk2 failed"
                fi
            fi
        fi
    fi

    if [[ "$have_journal" == "true" ]]; then
        local before after
        before=$(journal_usage_kb)
        if [[ "$DRY_RUN" == "true" ]]; then
            ((before > 0)) && skip_line "Journal logs older than 2 weeks · journal uses $(bytes_to_human_kb "$before") now"
        elif mole_c sudo journalctl --vacuum-time=2weeks > /dev/null 2>&1; then
            after=$(journal_usage_kb)
            if ((before > after)); then
                report_line "Journal logs older than 2 weeks" "$((before - after))" 1
                log_operation clean REMOVED /var/log/journal "journalctl --vacuum-time=2weeks"
                add_total "$((before - after))" 1
            fi
        fi
    fi
    end_section
}

main() {
    local initial_free
    initial_free=$(get_free_space_kb "$HOME")

    echo -e "${PURPLE_BOLD}Clean Your Linux${NC}"
    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}Dry Run Mode${NC}, Preview only, no deletions"
    elif [[ -t 0 ]]; then
        echo -e "${GRAY}${ICON_WARNING} Use --dry-run to preview${NC}"
    fi

    clean_user_rules
    clean_trash
    clean_system

    local heading size
    local -a details=()
    size=$(bytes_to_human_kb "$TOTAL_KB")
    if [[ "$DRY_RUN" == "true" ]]; then
        heading="Dry run complete - no changes made"
        if ((TOTAL_KB > 0)); then
            details+=("Potential space: $(colorize_human_size "$size") · $(mole_count_label "$TOTAL_ITEMS" item)")
        else
            details+=("No significant reclaimable space detected, system already clean.")
        fi
    else
        heading="Cleanup complete"
        if ((TOTAL_KB > 0)); then
            details+=("Removed: $(colorize_human_size "$size") · $(mole_count_label "$TOTAL_ITEMS" item)")
        else
            details+=("System was already clean; no additional space freed.")
        fi
        local final_free note=""
        final_free=$(get_free_space_kb "$HOME")
        if ((final_free > initial_free)); then
            note=" (+$(bytes_to_human_kb $((final_free - initial_free))))"
        fi
        details+=("Free space: $(bytes_to_human_kb "$final_free")$note")
    fi
    print_summary_block "$heading" "${details[@]}"
    if [[ "$SYSTEM_READY" == "true" ]]; then
        sudo -k 2> /dev/null || true
    fi
}

# Sourced by the bats tests for its functions; run directly otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
