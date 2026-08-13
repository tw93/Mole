#!/bin/bash
# Clean Homebrew caches and report orphaned dependencies
# Env: DRY_RUN
# Skips if run within 7 days, runs cleanup with package-manager timeouts
BREW_ACTIVE_LINK_PATHS=()
BREW_ACTIVE_LINK_TARGETS=()
BREW_ACTIVE_RESOLVED_TARGETS=()
BREW_ACTIVE_PREFIX=""
BREW_ACTIVE_CELLAR=""

brew_autoremove_preview_has_items() {
    local preview_file="$1"
    [[ -s "$preview_file" ]] || return 1
    grep -Eq '^(==> )?Would autoremove [0-9]+ unneeded formula' "$preview_file"
}

show_brew_autoremove_preview() {
    local preview_file="$1"
    echo -e "  ${GRAY}${ICON_WARNING}${NC} Homebrew autoremove would remove:"
    sed 's/^/    /' "$preview_file"
}

run_brew_autoremove_preview() {
    local timeout_seconds="$1"
    local preview_file="$2"

    HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_COLOR=1 NONINTERACTIVE=1 \
        run_with_timeout "$timeout_seconds" brew autoremove --dry-run > "$preview_file" 2>&1
}

# Resolve an existing path through any symlink chain without requiring GNU
# readlink -f (unavailable on the macOS versions Mole supports).
brew_cleanup_resolve_existing_path() {
    local path="$1"
    local target=""
    local hops=0

    [[ "$path" == /* ]] || return 1
    while [[ -L "$path" ]]; do
        target=$(readlink "$path" 2> /dev/null) || return 1
        if [[ "$target" == /* ]]; then
            path="$target"
        else
            path="${path%/*}/$target"
        fi
        hops=$((hops + 1))
        [[ $hops -le 32 ]] || return 1
    done

    [[ -e "$path" ]] || return 1
    local parent
    parent=$(cd "${path%/*}" 2> /dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$parent" "${path##*/}"
}

run_homebrew_link_restore_as_invoking_user() {
    /usr/bin/sudo -u "$SUDO_USER" -- "$@"
}

restore_homebrew_link() {
    local link_target="$1"
    local link_path="$2"

    if is_root_user; then
        [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]] || return 1
        # Homebrew's bin directories belong to the invoking user. Dropping
        # privileges for the actual write closes the parent-directory TOCTOU:
        # even if that user swaps bin after validation, root never follows it.
        run_homebrew_link_restore_as_invoking_user /bin/ln -s "$link_target" "$link_path"
        return $?
    fi

    /bin/ln -s "$link_target" "$link_path"
}

# Record active Homebrew executable links in memory before delegating to
# `brew cleanup`. A file in the invoking user's temp tree cannot safely
# authorize later link creation when the whole command is running as root.
snapshot_homebrew_active_links() {
    BREW_ACTIVE_LINK_PATHS=()
    BREW_ACTIVE_LINK_TARGETS=()
    BREW_ACTIVE_RESOLVED_TARGETS=()
    BREW_ACTIVE_PREFIX=""
    BREW_ACTIVE_CELLAR=""

    local prefix cellar
    prefix=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --prefix 2> /dev/null) || return 0
    cellar=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --cellar 2> /dev/null) || return 0
    [[ "$prefix" == /* && "$cellar" == /* && -d "$prefix" && -d "$cellar" ]] || return 0
    prefix=$(cd "$prefix" 2> /dev/null && pwd -P) || return 0
    cellar=$(cd "$cellar" 2> /dev/null && pwd -P) || return 0
    BREW_ACTIVE_PREFIX="$prefix"
    BREW_ACTIVE_CELLAR="$cellar"

    local link_dir link_path link_target resolved_target
    for link_dir in "$prefix/bin" "$prefix/sbin"; do
        [[ -d "$link_dir" ]] || continue
        while IFS= read -r -d '' link_path; do
            link_target=$(readlink "$link_path" 2> /dev/null) || continue
            case "$link_target" in
                "$cellar"/*)
                    [[ "$link_target" != *"/../"* && "$link_target" != */.. ]] || continue
                    resolved_target="$link_target"
                    ;;
                ../Cellar/*)
                    [[ "$cellar" == "$prefix/Cellar" ]] || continue
                    local cellar_relative="${link_target#../Cellar/}"
                    [[ -n "$cellar_relative" && "$cellar_relative" != ../* && "$cellar_relative" != *"/../"* && "$cellar_relative" != */.. ]] || continue
                    resolved_target="$cellar/$cellar_relative"
                    ;;
                *) continue ;;
            esac
            [[ -e "$resolved_target" ]] || continue
            case "$resolved_target" in
                "$cellar"/*)
                    BREW_ACTIVE_LINK_PATHS+=("$link_path")
                    BREW_ACTIVE_LINK_TARGETS+=("$link_target")
                    BREW_ACTIVE_RESOLVED_TARGETS+=("$resolved_target")
                    ;;
            esac
        done < <(command find "$link_dir" -mindepth 1 -maxdepth 1 -type l -print0 2> /dev/null)
    done
}

# Restore only links that disappeared while their exact pre-cleanup Cellar
# target still exists. Never overwrite a replacement or revive a removed keg.
restore_homebrew_active_links() {
    [[ ${#BREW_ACTIVE_LINK_PATHS[@]} -gt 0 ]] || return 0

    local prefix cellar
    prefix=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --prefix 2> /dev/null) || return 0
    cellar=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --cellar 2> /dev/null) || return 0
    [[ "$prefix" == /* && "$cellar" == /* && -d "$prefix" && -d "$cellar" ]] || return 0
    prefix=$(cd "$prefix" 2> /dev/null && pwd -P) || return 0
    cellar=$(cd "$cellar" 2> /dev/null && pwd -P) || return 0
    [[ "$prefix" == "$BREW_ACTIVE_PREFIX" && "$cellar" == "$BREW_ACTIVE_CELLAR" ]] || return 0

    local restored=0
    local failed=0
    local link_path link_target resolved_target expected_target relative_path
    local current_target current_parent
    local index
    for ((index = 0; index < ${#BREW_ACTIVE_LINK_PATHS[@]}; index++)); do
        link_path="${BREW_ACTIVE_LINK_PATHS[$index]}"
        link_target="${BREW_ACTIVE_LINK_TARGETS[$index]}"
        resolved_target="${BREW_ACTIVE_RESOLVED_TARGETS[$index]}"

        # Restore only direct children of the real Homebrew bin/sbin roots.
        case "$link_path" in
            "$prefix/bin/"*) relative_path="${link_path#"$prefix/bin/"}" ;;
            "$prefix/sbin/"*) relative_path="${link_path#"$prefix/sbin/"}" ;;
            *) continue ;;
        esac
        [[ -n "$relative_path" && "$relative_path" != */* ]] || continue
        [[ ! -e "$link_path" && ! -L "$link_path" ]] || continue

        case "$link_target" in
            "$cellar"/*)
                [[ "$link_target" != *"/../"* && "$link_target" != */.. ]] || continue
                expected_target="$link_target"
                ;;
            ../Cellar/*)
                [[ "$cellar" == "$prefix/Cellar" ]] || continue
                relative_path="${link_target#../Cellar/}"
                [[ -n "$relative_path" && "$relative_path" != ../* && "$relative_path" != *"/../"* && "$relative_path" != */.. ]] || continue
                expected_target="$cellar/$relative_path"
                ;;
            *) continue ;;
        esac
        [[ "$resolved_target" == "$expected_target" ]] || continue

        current_target=$(brew_cleanup_resolve_existing_path "$resolved_target") || continue
        case "$current_target" in
            "$cellar"/*) ;;
            *) continue ;;
        esac

        current_parent=$(cd "${link_path%/*}" 2> /dev/null && pwd -P) || continue
        [[ "$current_parent" == "${link_path%/*}" ]] || continue
        if restore_homebrew_link "$link_target" "$link_path" 2> /dev/null; then
            restored=$((restored + 1))
        else
            failed=$((failed + 1))
        fi
    done

    if [[ $restored -gt 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew links · restored ${restored} active executable(s)"
        note_activity
    fi
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Homebrew links · ${failed} could not be restored, run ${GRAY}brew link <formula>${NC}"
        note_activity
    fi
}

# Clean leftover cask staging files under var/homebrew/tmp/.caskroom.
# Homebrew stages cask installs here; an interrupted or failed upgrade (e.g.
# the app is running, or a .pkg installer needs sudo) leaves the <version>
# dir and its <version>.staged symlink behind, which can grow to several GB.
# Runs independently of the 7-day clean_homebrew throttle so leftovers are
# removed on every clean.
clean_homebrew_tmp_staged() {
    command -v brew > /dev/null 2>&1 || return 0
    # Never race an in-progress cask install.
    if pgrep -x brew > /dev/null 2>&1; then
        debug_log "Homebrew cask staging cleanup skipped: brew is running"
        return 0
    fi

    local prefix=""
    prefix=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 \
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" brew --prefix 2> /dev/null) || return 0
    [[ -n "$prefix" && -d "$prefix" ]] || return 0

    local staged_root="$prefix/var/homebrew/tmp/.caskroom"
    [[ -d "$staged_root" ]] || return 0

    if is_path_whitelisted "$staged_root"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Homebrew cask staging · would skip (whitelist)"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cask staging · skipped (whitelist)"
        fi
        note_activity
        return 0
    fi

    local removed=0
    local cask_dir link target resolved
    for cask_dir in "$staged_root"/*/; do
        [[ -d "$cask_dir" ]] || continue
        while IFS= read -r -d '' link; do
            target=$(readlink "$link" 2> /dev/null) || continue
            case "$target" in
                /*) resolved="$target" ;;
                *) resolved="$(cd "$(dirname "$link")" && pwd)/$target" ;;
            esac
            # Only ever remove leftovers inside the staging root.
            case "$resolved" in
                "$staged_root"/*) ;;
                *) continue ;;
            esac
            if [[ -e "$resolved" || -L "$resolved" ]]; then
                safe_remove "$resolved" || true
            fi
            safe_remove_symlink "$link" || true
            removed=$((removed + 1))
        done < <(find "$cask_dir" -maxdepth 1 -name "*.staged" -type l -print0 2> /dev/null)
    done

    if [[ $removed -gt 0 ]]; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Homebrew cask staging · would remove ${removed} leftover(s)"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cask staging · removed ${removed} leftover(s)"
        fi
        note_activity
    fi
}

clean_homebrew() {
    command -v brew > /dev/null 2>&1 || return 0
    local cleanup_timeout="${MOLE_TIMEOUT_PKG_CLEANUP_SEC:-20}"
    local autoremove_preview_timeout="${MOLE_TIMEOUT_PKG_LIST_SEC:-10}"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # Check if Homebrew cache is whitelisted
        if is_path_whitelisted "$HOME/Library/Caches/Homebrew"; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew · skipped (whitelist)"
            note_activity
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Homebrew · would cleanup"
            note_activity
            local dry_run_autoremove_file
            dry_run_autoremove_file=$(create_temp_file)
            local dry_run_autoremove_exit=0
            run_brew_autoremove_preview "$autoremove_preview_timeout" "$dry_run_autoremove_file" || dry_run_autoremove_exit=$?
            if [[ $dry_run_autoremove_exit -eq 0 ]] && brew_autoremove_preview_has_items "$dry_run_autoremove_file"; then
                show_brew_autoremove_preview "$dry_run_autoremove_file"
            elif [[ $dry_run_autoremove_exit -eq 124 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Autoremove preview timed out · run ${GRAY}brew autoremove --dry-run${NC} manually"
            fi
        fi
        return 0
    fi
    # Keep behavior consistent with dry-run preview.
    if is_path_whitelisted "$HOME/Library/Caches/Homebrew"; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew · skipped (whitelist)"
        note_activity
        return 0
    fi
    # Skip if cleaned recently to avoid repeated heavy operations.
    local brew_cache_file="${HOME}/.cache/mole/brew_last_cleanup"
    local cache_valid_days=7
    local should_skip=false
    if [[ -f "$brew_cache_file" ]]; then
        local last_cleanup
        last_cleanup=$(cat "$brew_cache_file" 2> /dev/null || echo "0")
        local current_time
        current_time=$(get_epoch_seconds)
        local time_diff=$((current_time - last_cleanup))
        local days_diff=$((time_diff / 86400))
        if [[ $days_diff -lt $cache_valid_days ]]; then
            should_skip=true
            local cleaned_when="cleaned ${days_diff}d ago"
            [[ $days_diff -eq 0 ]] && cleaned_when="cleaned today"
            debug_log "Homebrew cleanup skipped: ${cleaned_when}"
        fi
    fi
    [[ "$should_skip" == "true" ]] && return 0
    # Skip cleanup if cache is small; autoremove is previewed separately.
    local skip_cleanup=false
    local brew_cache_size=0
    if [[ -d ~/Library/Caches/Homebrew ]]; then
        brew_cache_size=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" du -skP ~/Library/Caches/Homebrew 2> /dev/null | awk '{print $1}')
        local du_exit=$?
        if [[ $du_exit -eq 0 && -n "$brew_cache_size" && "$brew_cache_size" -lt 51200 ]]; then
            skip_cleanup=true
        fi
    fi
    local brew_tmp_file
    local brew_exit=0
    if [[ "$skip_cleanup" == "false" ]]; then
        brew_tmp_file=$(create_temp_file)
        snapshot_homebrew_active_links || true
        if [[ -t 1 ]]; then MOLE_SPINNER_PREFIX="  " start_inline_spinner "Homebrew cleanup..."; fi
        HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_AUTOREMOVE=1 NONINTERACTIVE=1 \
            run_with_timeout "$cleanup_timeout" brew cleanup --prune=30 > "$brew_tmp_file" 2>&1 || brew_exit=$?
        if [[ -t 1 ]]; then stop_inline_spinner; fi
        restore_homebrew_active_links
    fi

    local brew_success=false
    if [[ "$skip_cleanup" == "false" && $brew_exit -eq 0 ]]; then
        brew_success=true
    fi

    # Process cleanup output and extract metrics
    # Summarize cleanup results.
    if [[ "$skip_cleanup" == "true" ]]; then
        debug_log "Homebrew cleanup skipped: cache below threshold (${brew_cache_size}KB)"
    elif [[ "$brew_success" == "true" && -f "$brew_tmp_file" ]]; then
        local brew_output
        brew_output=$(cat "$brew_tmp_file" 2> /dev/null || echo "")
        local removed_count freed_space
        removed_count=$(printf '%s\n' "$brew_output" | grep -c "Removing:" 2> /dev/null || true)
        freed_space=$(printf '%s\n' "$brew_output" | grep -o "[0-9.]*[KMGT]B freed" 2> /dev/null | tail -1 || true)
        if [[ $removed_count -gt 0 ]] || [[ -n "$freed_space" ]]; then
            if [[ -n "$freed_space" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup${NC} · ${GREEN}$freed_space${NC}"
                note_activity
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Homebrew cleanup · ${removed_count} items"
                note_activity
            fi
        fi
    elif [[ $brew_exit -eq 124 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Homebrew cleanup timed out · run ${GRAY}brew cleanup${NC} manually"
        note_activity
    fi
    local autoremove_preview_file
    autoremove_preview_file=$(create_temp_file)
    local autoremove_preview_exit=0
    run_brew_autoremove_preview "$autoremove_preview_timeout" "$autoremove_preview_file" || autoremove_preview_exit=$?
    if [[ $autoremove_preview_exit -eq 124 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autoremove preview timed out · run ${GRAY}brew autoremove --dry-run${NC} manually"
        # Keep the manual-action guidance visible past the idle-section erase.
        note_activity
    elif [[ $autoremove_preview_exit -ne 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autoremove preview failed · run ${GRAY}brew autoremove --dry-run${NC} manually"
        note_activity
    elif brew_autoremove_preview_has_items "$autoremove_preview_file"; then
        show_brew_autoremove_preview "$autoremove_preview_file"
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Homebrew autoremove · skipped (run ${GRAY}brew autoremove${NC} manually)"
        note_activity
    fi
    # Update cache timestamp on successful completion or when cleanup was intelligently skipped
    # This prevents repeated cache size checks within the 7-day window
    # Update cache timestamp when any work succeeded or was intentionally skipped.
    if [[ "$skip_cleanup" == "true" ]] || [[ "$brew_success" == "true" ]]; then
        ensure_user_file "$brew_cache_file"
        get_epoch_seconds > "$brew_cache_file"
    fi
}
