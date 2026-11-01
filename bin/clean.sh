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

trap 'stop_inline_spinner; show_cursor; mole_sudo_end; echo ""; exit 130' INT TERM

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

# Something Mole leaves for the user, with the command that would act on it.
review_line() {
    stop_section_spinner
    echo -e "  ${YELLOW}${ICON_REVIEW}${NC} $1"
    note_activity
}

add_total() {
    TOTAL_KB=$((TOTAL_KB + $1))
    TOTAL_ITEMS=$((TOTAL_ITEMS + $2))
}

# 0 when any owner runs, 1 when none does, 2 when a probe cannot tell.
rule_owner_state() {
    local owners="$1" token probe rc=1
    [[ -n "$owners" ]] || return 1
    if [[ "$owners" == flatpak:* ]]; then
        mole_flatpak_running "${owners#flatpak:}"
        return
    fi
    local -a tokens=() names=()
    IFS=',' read -ra tokens <<< "$owners"
    for token in "${tokens[@]}"; do
        [[ -n "$token" ]] || continue
        if [[ "$token" == cmd:* ]]; then
            command -v pgrep > /dev/null 2>&1 || return 2
            probe=0
            pgrep -f -u "$(id -u)" -- "${token#cmd:}" > /dev/null 2>&1 || probe=$?
            [[ $probe -eq 0 ]] && return 0
            [[ $probe -eq 1 ]] || rc=2
        else
            names+=("$token")
        fi
    done
    if [[ ${#names[@]} -gt 0 ]]; then
        probe=0
        mole_process_running "${names[@]}" || probe=$?
        [[ $probe -eq 0 ]] && return 0
        [[ $probe -eq 1 ]] || rc=2
    fi
    return "$rc"
}

# The name shown for a rule's owners: the first one, without its prefix.
rule_owner_name() {
    local first="${1%%,*}"
    first="${first#flatpak:}"
    printf '%s' "${first#cmd:}"
}

# 0 when the cache folder is not a plain folder of the user's inside $HOME
# (a symlink to another disk, an XDG_CACHE_HOME elsewhere). Every cache rule
# would refuse it anyway; clean says so once instead of reporting nothing.
cache_home_redirected() {
    local c="$MOLE_CACHE_HOME" real home_real
    [[ -e "$c" || -L "$c" ]] || return 1
    [[ "$c" == "$HOME/"* ]] || return 0
    real=$(readlink -f -- "$c" 2> /dev/null) || return 0
    home_real=$(readlink -f -- "$HOME" 2> /dev/null) || return 0
    [[ "$real" == "$home_real${c#"$HOME"}" ]] || return 0
    [[ -d "$c" && -O "$c" ]] || return 0
    return 1
}

# A group is one or more consecutive rules sharing a label, reported as one line.
G_LABEL=""
G_KB=0
G_COUNT=0
G_NOTE=""
group_begin() {
    G_LABEL="$1"
    G_KB=0
    G_COUNT=0
    G_NOTE=""
}
group_note() { [[ -n "$G_NOTE" ]] || G_NOTE="$1"; }
group_flush() {
    [[ -n "$G_LABEL" ]] || return 0
    if ((G_COUNT > 0 && G_KB > 0)); then
        report_line "$G_LABEL" "$G_KB" "$G_COUNT"
        add_total "$G_KB" "$G_COUNT"
    elif [[ -n "$G_NOTE" ]]; then
        skip_line "$G_NOTE"
    fi
    G_LABEL=""
    return 0
}

# Clean one rule into the current group. Only children mole_remove_cache would
# accept are sized and counted, in a dry run as in a real one.
clean_rule_collect() {
    local label="$1" root="$2" owners="$3" selector="${4:-}"
    if [[ "$selector" == tool:uv ]]; then
        clean_uv_cache "$label" "$root" "$owners"
        return 0
    fi
    [[ -n "$root" && -d "$root" && ! -L "$root" ]] || return 0
    local -a children=() eligible=()
    local child
    while IFS= read -r -d '' child; do
        children+=("$child")
    done < <(mole_rule_children "$root" "$selector")
    [[ ${#children[@]} -gt 0 ]] || return 0

    local kb=0
    for child in "${children[@]}"; do
        mole_cache_child_ok "$child" "$root" || continue
        eligible+=("$child")
        kb=$((kb + $(mole_path_kb "$child")))
    done
    [[ ${#eligible[@]} -gt 0 ]] || return 0
    ((kb >= 8)) || return 0

    # An owner that runs, or a probe that cannot tell, skips the rule.
    local rc=0
    rule_owner_state "$owners" || rc=$?
    if [[ $rc -eq 0 ]]; then
        group_note "$label · skipped while $(rule_owner_name "$owners") is running"
        return 0
    elif [[ $rc -ne 1 ]]; then
        group_note "$label · skipped (process state unknown)"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        G_KB=$((G_KB + kb))
        G_COUNT=$((G_COUNT + ${#eligible[@]}))
        return 0
    fi
    local removed=0 failed=0 left=0
    for child in "${eligible[@]}"; do
        if mole_remove_cache "$child" "$root" clean "$label"; then
            removed=$((removed + 1))
        else
            failed=$((failed + 1))
            left=$((left + $(mole_path_kb "$child")))
        fi
    done
    G_KB=$((G_KB + (kb > left ? kb - left : 0)))
    G_COUNT=$((G_COUNT + removed))
    ((failed > 0)) && debug_log "$label: $failed item(s) not removed"
    return 0
}

# One rule on its own line (the tests' entry point).
clean_rule() {
    group_begin "$1"
    clean_rule_collect "$@"
    group_flush
}

# uv hardlinks (or symlinks) its cache into every virtualenv, so deleting the
# folder frees little and can break environments. Only uv's own prune runs,
# and only when uv is installed (Mac: lib/clean/dev.sh clean_uv_cache).
clean_uv_cache() {
    local label="$1" root="$2" owners="$3" dir
    command -v uv > /dev/null 2>&1 || return 0
    dir=$(mole_c timeout 10 uv cache dir 2> /dev/null) || return 0
    [[ "$dir" == /* && "$dir" != *$'\n'* && -d "$dir" ]] || return 0
    local rc=0
    rule_owner_state "$owners" || rc=$?
    if [[ $rc -eq 0 ]]; then
        group_note "$label · skipped while uv is running"
        return 0
    elif [[ $rc -ne 1 ]]; then
        group_note "$label · skipped (process state unknown)"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        group_note "$label · would run uv cache prune"
        return 0
    fi
    # Free space, not du: hardlinked files cost nothing to keep.
    local before after
    before=$(get_free_space_kb "$dir")
    if UV_LOCK_TIMEOUT=10 mole_c timeout 300 uv cache prune > /dev/null 2>&1; then
        after=$(get_free_space_kb "$dir")
        log_operation clean REMOVED "$dir" "uv cache prune"
        if ((after > before)); then
            G_KB=$((G_KB + after - before))
            G_COUNT=$((G_COUNT + 1))
        fi
    else
        debug_log "uv cache prune failed"
    fi
    return 0
}

clean_user_rules() {
    local current="" section label root owners selector redirected=false told=false
    cache_home_redirected && redirected=true
    while IFS='|' read -r section label root owners selector; do
        [[ -n "$section" ]] || continue
        if [[ "$section" != "$current" ]]; then
            group_flush
            if [[ -n "$current" ]]; then
                stop_section_spinner
                end_section
            fi
            current="$section"
            start_section "$section"
        fi
        if [[ "$redirected" == true && "$root" == "$MOLE_CACHE_HOME/"* ]]; then
            if [[ "$told" == false ]]; then
                group_flush
                skip_line "Cache folder $(mole_display_path "$MOLE_CACHE_HOME") is redirected elsewhere · left alone"
                told=true
            fi
            continue
        fi
        [[ "$label" == "$G_LABEL" ]] || {
            group_flush
            group_begin "$label"
        }
        start_section_spinner "Scanning $label..."
        clean_rule_collect "$label" "$root" "$owners" "$selector"
    done < <(mole_clean_rules)
    group_flush
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
    local -a entries=() eligible=()
    local e
    while IFS= read -r -d '' e; do entries+=("$e"); done < <(find "$files" -mindepth 1 -maxdepth 1 -print0 2> /dev/null)
    if [[ ${#entries[@]} -eq 0 ]]; then
        end_section
        return 0
    fi
    local kb=0 removed=0 left=0 meta
    for e in "${entries[@]}"; do
        mole_cache_child_ok "$e" "$files" || continue
        eligible+=("$e")
        kb=$((kb + $(mole_path_kb "$e")))
    done
    for e in ${eligible[@]+"${eligible[@]}"}; do
        if mole_remove_cache "$e" "$files" clean "Trash"; then
            removed=$((removed + 1))
            meta="$info/$(basename -- "$e").trashinfo"
            [[ -f "$meta" ]] && mole_remove_cache "$meta" "$info" clean "Trash info" || true
        else
            left=$((left + $(mole_path_kb "$e")))
        fi
    done
    kb=$((kb > left ? kb - left : 0))
    if ((removed > 0)); then
        report_line "Trash" "$kb" "$removed"
        add_total "$kb" "$removed"
    fi
    end_section
}

# The largest ~/.cache folders no rule knows: listed with their size, never
# selected. Folders that hold a rule's root (JetBrains, mozilla) are left out.
report_unknown_caches() {
    local c="$MOLE_CACHE_HOME"
    [[ -d "$c" && ! -L "$c" ]] || return 0
    cache_home_redirected && return 0
    local -a roots=()
    local section label root rest
    while IFS='|' read -r section label root rest; do
        [[ -n "$root" ]] && roots+=("$root")
    done < <(mole_clean_rules)
    local rows="" kb path known r
    while IFS=$'\t' read -r -d '' kb path; do
        [[ "$path" == "$c/"* && "${path#"$c/"}" != */* ]] || continue
        [[ "$kb" =~ ^[0-9]+$ ]] || continue
        ((kb >= 102400)) || continue
        known=false
        for r in "${roots[@]}"; do
            [[ "$r" == "$path" || "$r" == "$path/"* ]] && known=true && break
        done
        [[ "$known" == false && "$path" != "$c/mole" ]] || continue
        rows+="$kb"$'\t'"$path"$'\n'
    done < <(mole_c du -xk -d 1 -0 -- "$c" 2> /dev/null)
    [[ -n "$rows" ]] || return 0
    start_section "Not cleaned"
    while IFS=$'\t' read -r kb path; do
        [[ -n "$path" ]] || continue
        review_line "$(mole_display_path "$path") · $(colorize_human_size "$(bytes_to_human_kb "$kb")")"
    done < <(printf '%s' "$rows" | sort -t $'\t' -k1,1 -rn | head -5)
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

have_paccache() { command -v paccache > /dev/null 2>&1 && [[ -d /var/cache/pacman/pkg ]]; }
have_journal() { command -v journalctl > /dev/null 2>&1; }

# Ask for sudo once, before anything is cleaned, like Mole CLI (macOS): Enter
# asks for the password, Space skips the System section, ESC cancels.
prompt_for_system_clean() {
    [[ "$DRY_RUN" != "true" ]] || return 0
    have_paccache || have_journal || return 0
    if sudo -n true 2> /dev/null; then
        mole_sudo_ready && SYSTEM_READY=true
        [[ -t 1 ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access already available"
        return 0
    fi
    [[ -t 0 ]] || return 0
    local key attempt=0
    while true; do
        echo -ne "${PURPLE}${ICON_ARROW}${NC} Package cache and journal need sudo. ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "
        key=$(read_key) || key="QUIT"
        case "$key" in
            ENTER)
                printf '\r\033[K'
                mole_sudo_ready && SYSTEM_READY=true
                break
                ;;
            SPACE)
                echo -e "${GRAY}Skipped${NC}"
                break
                ;;
            QUIT)
                echo -e "${GRAY}Cancelled${NC}"
                exit 0
                ;;
            *)
                attempt=$((attempt + 1))
                printf '\r\033[K'
                if ((attempt >= 2)); then
                    echo -e "${PURPLE}${ICON_ARROW}${NC} Package cache and journal need sudo. ${GRAY}Skipped${NC}"
                    break
                fi
                ;;
        esac
    done
}

clean_system() {
    local have_paccache=false have_journal=false
    have_paccache && have_paccache=true
    have_journal && have_journal=true
    [[ "$have_paccache" == "true" || "$have_journal" == "true" ]] || return 0

    start_section "System"
    if [[ "$DRY_RUN" != "true" && "$SYSTEM_READY" != "true" ]]; then
        skip_line "Package cache and journal · skipped without sudo"
        end_section
        return 0
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
            # The vacuum ran as root; it is logged even when the size could
            # not be read before and after.
            log_operation clean REMOVED /var/log/journal "journalctl --vacuum-time=2weeks, $(bytes_to_human_kb "$before") before, $(bytes_to_human_kb "$after") after"
            if ((before > after)); then
                report_line "Journal logs older than 2 weeks" "$((before - after))" 1
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
    prompt_for_system_clean

    clean_user_rules
    clean_trash
    report_unknown_caches
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
    mole_sudo_end
}

# Sourced by the bats tests for its functions; run directly otherwise.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
