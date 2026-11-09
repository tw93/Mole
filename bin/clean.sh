#!/bin/bash
# Mole CLI (Linux) - clean: remove regenerable caches from an allowlist, empty
# the Trash, and trim the package cache and journal through their own tools.

set -euo pipefail

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}"
source "$SCRIPT_DIR/lib/core/common.sh"
source "$SCRIPT_DIR/lib/clean/rules.sh"
source "$SCRIPT_DIR/lib/clean/whitelist.sh"
mole_refuse_root

DRY_RUN=false
WHITELIST_MODE=false
GPU_SHADERS=false
for arg in "$@"; do
    case "$arg" in
        --dry-run | -n) DRY_RUN=true ;;
        --whitelist) WHITELIST_MODE=true ;;
        --gpu-shaders) GPU_SHADERS=true ;;
        --debug) export MO_DEBUG=1 ;;
        -h | --help)
            echo "Usage: mo clean [OPTIONS]"
            echo ""
            echo "Remove caches that apps rebuild by themselves, empty the Trash, and trim"
            echo "old package files and journal logs through pacman's, apt's and systemd's own tools."
            echo ""
            echo "Options:"
            echo "  --dry-run, -n     Preview cleanup without making changes"
            echo "  --whitelist       Choose what clean keeps"
            echo "  --gpu-shaders     Also clean GPU shader caches (games compile them again on next launch)"
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

whitelist_note() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s · would skip (whitelist)' "$1"
    else
        printf '%s · skipped (whitelist)' "$1"
    fi
}

# 0 when any owner runs, 1 when none does, 2 when a probe cannot tell.
rule_owner_state() {
    local owners="$1" token probe rc=1
    [[ -n "$owners" ]] || return 1
    if [[ "$owners" == flatpak:* ]]; then
        mole_flatpak_running "${owners#flatpak:}"
        return
    fi
    if [[ "$owners" == snap:* ]]; then
        mole_snap_running "${owners#snap:}"
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
    first="${first#snap:}"
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
    # Old agent versions whose running one cannot be told: said once, kept.
    if [[ "$selector" == versions:* ]] && ! mole_versions_probe "${selector#versions:}"; then
        local n=0
        for child in "$root"/[0-9]*; do [[ -e "$child" ]] && n=$((n + 1)); done
        ((n > 2)) && group_note "$label · skipped (process state unknown)"
        return 0
    fi
    while IFS= read -r -d '' child; do
        children+=("$child")
    done < <(mole_rule_children "$root" "$selector")
    [[ ${#children[@]} -gt 0 ]] || return 0

    if mole_whitelisted "$label" "$root"; then
        group_note "$(whitelist_note "$label")"
        return 0
    fi

    local kb=0 kept=0
    for child in "${children[@]}"; do
        if mole_whitelist_keeps_child "$child"; then
            kept=$((kept + 1))
            continue
        fi
        mole_cache_child_ok "$child" "$root" || continue
        eligible+=("$child")
        kb=$((kb + $(mole_path_kb "$child")))
    done
    if [[ ${#eligible[@]} -eq 0 ]]; then
        ((kept > 0)) && group_note "$(whitelist_note "$label")"
        return 0
    fi
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
    if mole_whitelisted "$label" "$dir" || mole_whitelisted "$label" "$root"; then
        group_note "$(whitelist_note "$label")"
        return 0
    fi
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
        [[ "$section" == "GPU shaders" && "$GPU_SHADERS" != true ]] && continue
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
    if mole_whitelisted "Trash" "$MOLE_TRASH_DIR"; then
        skip_line "$(whitelist_note Trash)"
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

PACMAN_CACHE_DIR=/var/cache/pacman/pkg
have_paccache() { command -v paccache > /dev/null 2>&1 && [[ -d "$PACMAN_CACHE_DIR" ]]; }
have_journal() { command -v journalctl > /dev/null 2>&1; }
APT_ARCHIVES_DIR="${APT_ARCHIVES_DIR:-/var/cache/apt/archives}"
have_apt_cache() { command -v apt-get > /dev/null 2>&1 && command -v dpkg > /dev/null 2>&1 && [[ -d "$APT_ARCHIVES_DIR" ]]; }
SNAPD_SNAPS_DIR="${SNAPD_SNAPS_DIR:-/var/lib/snapd/snaps}"
have_flatpak() { command -v flatpak > /dev/null 2>&1; }
have_user_flatpak() { have_flatpak && [[ -d "$MOLE_DATA_HOME/flatpak/repo" ]]; }
SYSTEM_FLATPAK_DIR=/var/lib/flatpak
have_system_flatpak() { have_flatpak && [[ -d "$SYSTEM_FLATPAK_DIR/repo" ]]; }

# What the sudo step covers on this machine, for the prompt and skip lines.
sudo_items_label() {
    local -a items=()
    if have_paccache || have_apt_cache; then items+=("Package cache"); fi
    have_journal && items+=("journal")
    local IFS=','
    local joined="${items[*]}"
    joined="${joined//,/, }"
    # Capitalize the first item only.
    printf '%s' "${joined^}" | sed -E 's/, ([^,]+)$/ and \1/'
}

# The label with its verb: "Journal needs sudo", "Package cache and journal need sudo".
sudo_items_phrase() {
    local what
    what=$(sudo_items_label)
    if [[ "$what" == *" and "* ]]; then echo "$what need sudo"; else echo "$what needs sudo"; fi
}

# Ask for sudo once, before anything is cleaned, like Mole CLI (macOS): Enter
# asks for the password, Space skips the sudo items, ESC cancels.
prompt_for_system_clean() {
    [[ "$DRY_RUN" != "true" ]] || return 0
    have_paccache || have_apt_cache || have_journal || return 0
    if sudo -n true 2> /dev/null; then
        mole_sudo_ready && SYSTEM_READY=true
        [[ -t 1 ]] && echo -e "${GREEN}${ICON_SUCCESS}${NC} Admin access already available"
        return 0
    fi
    [[ -t 0 ]] || return 0
    local key attempt=0 what
    what=$(sudo_items_phrase)
    while true; do
        echo -ne "${PURPLE}${ICON_ARROW}${NC} $what. ${GREEN}Enter${NC} continue, ${GRAY}Space${NC} skip: "
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
                    echo -e "${PURPLE}${ICON_ARROW}${NC} $what. ${GRAY}Skipped${NC}"
                    break
                fi
                ;;
        esac
    done
}

# Unused Flatpak runtimes of the user installation, through flatpak itself
# (pinned runtimes and those an app uses stay); no sudo.
clean_flatpak_unused() {
    local dir="$MOLE_DATA_HOME/flatpak" label="Unused Flatpak runtimes"
    if mole_whitelisted "$label" "$dir"; then
        skip_line "$(whitelist_note "$label")"
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        skip_line "$label · would run flatpak uninstall --user --unused"
        return 0
    fi
    local before after
    before=$(mole_path_kb "$dir")
    if mole_c timeout 900 flatpak uninstall --user --unused --noninteractive > /dev/null 2>&1; then
        after=$(mole_path_kb "$dir")
        log_operation clean REMOVED "$dir" "flatpak uninstall --user --unused, $(bytes_to_human_kb "$before") before, $(bytes_to_human_kb "$after") after"
        if ((before > after)); then
            report_line "$label" "$((before - after))" 1
            add_total "$((before - after))" 1
        fi
    else
        log_error "flatpak uninstall --user --unused failed"
    fi
}

# Report-only: the system installation's unused runtimes. Under sudo, flatpak
# may not see the desktop user's per-user apps and could remove a system
# runtime they still use, so Mole runs nothing there. No read-only flatpak
# query says which runtimes are unused, so the line names the command only.
report_system_flatpak_unused() {
    local label="Unused Flatpak runtimes (system)"
    mole_whitelisted "$label" "$SYSTEM_FLATPAK_DIR" && return 0
    # Quiet when the system installation holds no runtime at all.
    [[ -n "$(mole_c timeout 20 flatpak list --system --runtime --columns=ref 2> /dev/null)" ]] || return 0
    review_line "$label · ${GRAY}sudo flatpak uninstall --system --unused${NC}"
}

# Report-only: core dumps systemd-coredump kept. Never removed by Mole.
report_coredumps() {
    command -v coredumpctl > /dev/null 2>&1 || return 0
    local count kb
    count=$(mole_c timeout 10 coredumpctl list --no-pager --no-legend 2> /dev/null | grep -c . || true)
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    ((count > 0)) || return 0
    kb=$(mole_path_kb /var/lib/systemd/coredump)
    ((kb >= 1024)) || return 0
    review_line "Core dumps · $(mole_count_label "$count" dump), $(colorize_human_size "$(bytes_to_human_kb "$kb")"), ${GRAY}sudo rm /var/lib/systemd/coredump/core.*${NC}"
}

# 0 when a Docker daemon socket exists to ask: DOCKER_HOST's unix path, else
# the system, Docker Desktop (~/.docker/desktop) and rootless sockets. A tcp
# DOCKER_HOST is the user's own choice.
docker_daemon_present() {
    local host="${DOCKER_HOST:-}"
    if [[ -n "$host" ]]; then
        [[ "$host" == unix://* ]] || return 0
        [[ -S "${host#unix://}" ]]
        return
    fi
    local sys
    # MOLE_DOCKER_SYSTEM_SOCKETS lets tests replace the system paths (CI
    # containers have the host's /var/run/docker.sock mounted).
    for sys in ${MOLE_DOCKER_SYSTEM_SOCKETS-/var/run/docker.sock /run/docker.sock}; do
        [[ -S "$sys" ]] && return 0
    done
    [[ -S "$HOME/.docker/desktop/docker.sock" ]] && return 0
    [[ -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/docker.sock" ]]
}

# Report-only: what Docker or Podman says it could reclaim, when it answers
# without sudo. Mole never prunes containers, images or volumes. Podman is
# asked only when its storage exists (podman system df would create it), and
# Docker only when a daemon socket is there.
report_container_storage() {
    local tool out type reclaim total kb
    for tool in docker podman; do
        command -v "$tool" > /dev/null 2>&1 || continue
        if [[ "$tool" == podman ]]; then
            [[ -d "$MOLE_DATA_HOME/containers" ]] || continue
        else
            docker_daemon_present || continue
        fi
        out=$(mole_c timeout 10 "$tool" system df --format '{{.Type}}\t{{.Reclaimable}}' 2> /dev/null) || continue
        total=0
        while IFS=$'\t' read -r type reclaim; do
            [[ -n "$type" ]] || continue
            kb=$(human_to_kb "${reclaim%% *}")
            [[ "$kb" =~ ^[0-9]+$ ]] && total=$((total + kb))
        done <<< "$out"
        ((total >= 102400)) || continue
        review_line "${tool^} reclaimable · $(colorize_human_size "$(bytes_to_human_kb "$total")"), ${GRAY}$tool system prune${NC}"
    done
}

clean_system() {
    local have_paccache=false have_apt=false have_journal=false user_flatpak=false system_flatpak=false
    have_paccache && have_paccache=true
    have_apt_cache && have_apt=true
    have_journal && have_journal=true
    have_user_flatpak && user_flatpak=true
    have_system_flatpak && system_flatpak=true

    start_section "System"
    [[ "$user_flatpak" == "true" ]] && clean_flatpak_unused

    if [[ "$have_paccache" == "true" || "$have_apt" == "true" || "$have_journal" == "true" ]]; then
        if [[ "$DRY_RUN" != "true" && "$SYSTEM_READY" != "true" ]]; then
            skip_line "$(sudo_items_label) · skipped without sudo"
        else
            clean_system_sudo_items "$have_paccache" "$have_journal" "$have_apt"
        fi
    fi
    [[ "$system_flatpak" == "true" ]] && report_system_flatpak_unused
    report_snap_revisions

    report_coredumps
    report_container_storage
    end_section
}

clean_system_sudo_items() {
    local have_paccache="$1" have_journal="$2" have_apt="${3:-false}"
    if [[ "$have_paccache" == "true" ]]; then
        if mole_whitelisted "Package cache" "$PACMAN_CACHE_DIR"; then
            skip_line "$(whitelist_note "Package cache")"
        elif [[ -e /var/lib/pacman/db.lck ]]; then
            skip_line "Package cache · skipped while pacman is running"
        else
            local out kb=0 count=0
            out=$(mole_c paccache -dk2 2> /dev/null | tail -1) || out=""
            if [[ "$out" =~ ([0-9]+)\ candidate.*saved:\ ([0-9.]+\ [KMGT]i?B) ]]; then
                count="${BASH_REMATCH[1]}"
                kb=$(human_to_kb "${BASH_REMATCH[2]}")
            fi
            if ((count > 0)); then
                # On a subvolume snapper snapshots (Omarchy snapshots / before
                # each update), the old packages stay in those snapshots: the
                # space comes back only as they rotate, so it is not counted as
                # freed. A probe that cannot tell keeps the plain row.
                local note=" ${GRAY}(keeps 2)${NC}" freed_kb="$kb" state=0
                mole_snapshot_state "$PACMAN_CACHE_DIR" || state=$?
                if ((state == 0)); then
                    note=" ${GRAY}(keeps 2, freed as snapshots rotate)${NC}"
                    freed_kb=0
                fi
                if [[ "$DRY_RUN" == "true" ]]; then
                    report_line "Package cache, older versions" "$kb" "$count" "$note"
                    add_total "$freed_kb" "$count"
                elif mole_c sudo paccache -rk2 > /dev/null 2>&1; then
                    report_line "Package cache, older versions" "$kb" "$count" "$note"
                    log_operation clean REMOVED "$PACMAN_CACHE_DIR" "paccache -rk2, $count files"
                    add_total "$freed_kb" "$count"
                else
                    log_error "paccache -rk2 failed"
                fi
            fi
        fi
    fi

    [[ "$have_apt" == "true" ]] && clean_apt_cache

    if [[ "$have_journal" == "true" ]]; then
        local before after
        if mole_whitelisted "Journal logs" /var/log/journal; then
            skip_line "$(whitelist_note "Journal logs")"
        else
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
    fi

    return 0
}

# apt's own answer to what autoclean would delete: "Del <pkg> <ver> [<size>]"
# per package file that can no longer be downloaded. Prints "<count> <kb>".
apt_autoclean_preview() {
    # apt prints sizes in powers of 1000 (300 kB is 300000 bytes).
    mole_c apt-get -s autoclean 2> /dev/null | LC_ALL=C awk '
        /^Del [^ ]+ [^ ]+ \[[0-9.,]+ ?[kKMGT]?B\]$/ {
            s = $NF; sub(/\]$/, "", s); v = $(NF - 1); sub(/^\[/, "", v); gsub(/,/, "", v)
            if (v ~ /B\]?$/) { s = v; v = v + 0; sub(/^[0-9.]+/, "", s) }
            u = toupper(substr(s, 1, 1)); m = 1
            if (u == "K") m = 1e3; else if (u == "M") m = 1e6; else if (u == "G") m = 1e9; else if (u == "T") m = 1e12
            n++; bytes += v * m
        }
        END { printf "%d %d\n", n, bytes / 1024 }'
}

# Debian and Ubuntu: apt-get autoclean deletes only the package files apt can
# no longer download, the counterpart of paccache -rk2; apt-get clean, which
# empties the cache, is never run. Skipped while apt or dpkg runs.
clean_apt_cache() {
    if mole_whitelisted "Package cache" "$APT_ARCHIVES_DIR"; then
        skip_line "$(whitelist_note "Package cache")"
        return 0
    fi
    local busy=0
    mole_apt_busy || busy=$?
    if [[ $busy -ne 1 ]]; then
        skip_line "Package cache · skipped while apt or dpkg is running"
        return 0
    fi
    local count kb
    read -r count kb < <(apt_autoclean_preview) || { count=0; kb=0; }
    ((count > 0)) || return 0
    local note=" ${GRAY}(no longer downloadable)${NC}" freed_kb="$kb" state=0
    mole_snapshot_state "$APT_ARCHIVES_DIR" || state=$?
    if ((state == 0)); then
        note=" ${GRAY}(no longer downloadable, freed as snapshots rotate)${NC}"
        freed_kb=0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        report_line "Package cache, old package files" "$kb" "$count" "$note"
        add_total "$freed_kb" "$count"
    elif mole_c sudo apt-get autoclean > /dev/null 2>&1; then
        report_line "Package cache, old package files" "$kb" "$count" "$note"
        log_operation clean REMOVED "$APT_ARCHIVES_DIR" "apt-get autoclean, $count files"
        add_total "$freed_kb" "$count"
    else
        log_error "apt-get autoclean failed"
    fi
}

# Snap keeps the previous revision of each snap (refresh.retain, at least 2)
# so snap revert can roll back; Mole never removes them, it only says how much
# they take and the command, the same choice as keeping two versions in
# paccache. Sizes are the .snap files, which every user can stat.
report_snap_revisions() {
    command -v snap > /dev/null 2>&1 || return 0
    local label="Snap previous revisions"
    mole_whitelisted "$label" "$SNAPD_SNAPS_DIR" && return 0
    local out line name rev notes bytes total=0 apps=0 first=""
    out=$(mole_c timeout 20 snap list --all 2> /dev/null) || return 0
    declare -A seen=()
    while IFS= read -r line; do
        read -r name _ rev _ _ notes <<< "$line"
        [[ "$name" == Name || -z "$rev" ]] && continue
        [[ ",$notes," == *",disabled,"* ]] || continue
        [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ && "$rev" =~ ^x?[0-9]+$ ]] || continue
        bytes=$(stat -c %s -- "$SNAPD_SNAPS_DIR/${name}_${rev}.snap" 2> /dev/null) || continue
        total=$((total + bytes))
        [[ -n "${seen[$name]:-}" ]] || apps=$((apps + 1))
        seen[$name]=1
        [[ -n "$first" ]] || first="$name --revision=$rev"
    done <<< "$out"
    ((total >= 1048576)) || return 0
    review_line "$label · $(colorize_human_size "$(bytes_to_human_kb "$((total / 1024))")"), $(mole_count_label "$apps" app) keep one for snap revert · ${GRAY}sudo snap remove $first${NC}"
}

# Prints the refusal behind an error line, or fails when the line is anything
# else. Only the text after the last ": " counts, since mktemp quotes the path.
_clean_write_refusal() {
    local message="${1##*: }"
    case "$message" in
        "Operation not permitted" | "Permission denied" | "Read-only file system")
            printf '%s' "$message"
            return 0
            ;;
    esac
    return 1
}

# Creates and removes one empty folder in $1. Prints the reason and succeeds only
# when the system refused the write.
_clean_write_check() {
    local output="" path=""
    if ! output=$(LC_ALL=C mktemp -d "$1/.mole-write-check.XXXXXX" 2>&1); then
        _clean_write_refusal "${output##*$'\n'}"
        return
    fi
    path="${output##*$'\n'}"
    if output=$(LC_ALL=C rmdir -- "$path" 2>&1); then
        return 1
    fi
    _clean_write_refusal "${output##*$'\n'}"
}

# A shell that may not write here, such as an agent's sandbox, has every delete
# denied, and a denied delete reads as nothing to clean: the run would end on
# "Cleanup complete" and exit 0 with nothing removed. Only an explicit refusal
# stops the run, and only when every checked folder refuses. Any other failure
# carries on, above all a full disk, which is what people run this for.
refuse_cleanup_without_write_access() {
    [[ "$DRY_RUN" == "true" ]] && return 0
    local target="" reason="" refused_target="" refused_reason=""
    for target in "$HOME/.cache" "$HOME/.local/share"; do
        [[ -d "$target" ]] || continue
        reason=$(_clean_write_check "$target") || return 0
        if [[ -z "$refused_target" ]]; then
            refused_target="$target"
            refused_reason="$reason"
        fi
    done
    [[ -n "$refused_target" ]] || return 0

    printf 'mo clean cannot remove files from this shell: writing to %s was refused (%s).\n' "$(mole_display_path "$refused_target")" "$refused_reason" >&2
    printf 'Nothing was removed.' >&2
    [[ "$refused_reason" == "Read-only file system" ]] || printf ' If this shell runs in a sandbox, run mo clean in your own terminal.' >&2
    printf '\n' >&2
    return 1
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
    if ! mole_whitelist_load; then
        echo "Cannot read $(mole_display_path "$MOLE_WHITELIST_FILE"); fix or remove it, then run mo clean again." >&2
        exit 1
    fi
    refuse_cleanup_without_write_access || exit 1
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
    if [[ "$WHITELIST_MODE" == "true" ]]; then
        source "$SCRIPT_DIR/lib/ui/menu_paginated.sh"
        manage_whitelist
        exit $?
    fi
    main
fi
