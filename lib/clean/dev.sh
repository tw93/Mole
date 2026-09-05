#!/bin/bash
# Developer Tools Cleanup Module
set -euo pipefail

# Tool cache helper (respects DRY_RUN and whitelist).
# Args:
#   $1 = description (display name)
#   $2 = cache path to check against whitelist (empty string to skip check)
#   $3+ = command to run
clean_tool_cache() {
    local description="$1"
    local cache_path="$2"
    shift 2

    if [[ -n "$cache_path" ]] && is_path_whitelisted "$cache_path"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $description · would skip (whitelist)"
            note_activity
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $description · skipped (whitelist)"
            note_activity
        fi
        return 0
    fi

    if [[ "$DRY_RUN" != "true" ]]; then
        local command_succeeded=false
        if [[ -t 1 ]]; then
            start_section_spinner "Cleaning $description..."
        fi
        if "$@" > /dev/null 2>&1; then
            command_succeeded=true
        fi
        if [[ -t 1 ]]; then
            stop_section_spinner
        fi
        if [[ "$command_succeeded" == "true" ]]; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $description"
            note_activity
        fi
    else
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $description · would clean"
        note_activity
    fi
    return 0
}

clean_corepack_cache() {
    local corepack_home="${COREPACK_HOME:-$HOME/.cache/node/corepack}"
    [[ -n "$corepack_home" && "$corepack_home" == /* ]] || return 0
    case "$corepack_home" in
        / | "$HOME" | "$HOME/" | "$HOME/Library" | "$HOME/Library/")
            debug_log "Skipping unsafe Corepack cache path: $corepack_home"
            return 0
            ;;
    esac
    # COREPACK_ENABLE_DOWNLOAD_PROMPT=0 mirrors the pnpm path above: without it
    # corepack can stop on an interactive "download? [Y/n]" prompt. Because the
    # call is wrapped with stdout/stderr to /dev/null, that prompt is invisible
    # and the command looks frozen until the timeout fires (seen on a Node setup
    # where corepack is installed; machines without corepack take the else
    # branch and never hit this).
    if command -v corepack > /dev/null 2>&1 && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" corepack --version > /dev/null 2>&1; then
        COREPACK_ENABLE_DOWNLOAD_PROMPT=0 clean_tool_cache "Corepack cache" "$corepack_home" run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" corepack cache clean
    else
        safe_clean "$corepack_home"/* "Corepack cache"
    fi
}

clean_uv_cache() {
    local uv_cache_path="$HOME/.cache/uv"
    if command -v uv > /dev/null 2>&1 && run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" uv --version > /dev/null 2>&1; then
        local detected_cache
        detected_cache=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" uv cache dir 2> /dev/null || true)
        if [[ -n "$detected_cache" && "$detected_cache" == /* ]]; then
            uv_cache_path="$detected_cache"
        fi
        clean_tool_cache "uv cache" "$uv_cache_path" run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" uv cache prune
    else
        safe_clean "$uv_cache_path"/* "uv cache"
    fi
}

github_cli_process_state() {
    mole_pgrep_any -x gh
}

_run_github_cli_clear_cache_bound() {
    local cache_path="$1"
    local expected_parent="$2"
    local expected_parent_id="$3"
    local expected_target_id="$4"

    _MOLE_GITHUB_CLI_CLEAR_REASON=""
    local process_state=0
    github_cli_process_state || process_state=$?
    if [[ $process_state -eq 0 ]]; then
        _MOLE_GITHUB_CLI_CLEAR_REASON="owner active"
        return 1
    fi
    if [[ $process_state -ne 1 ]]; then
        _MOLE_GITHUB_CLI_CLEAR_REASON="process state unknown"
        return 1
    fi

    if ! _mole_path_matches_identity \
        "$cache_path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        _MOLE_GITHUB_CLI_CLEAR_REASON="cache path changed"
        return 1
    fi

    local command_status=0
    run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" \
        env XDG_CACHE_HOME="$expected_parent" gh config clear-cache || command_status=$?
    if [[ $command_status -ne 0 && $command_status -ne 124 && $command_status -lt 128 ]]; then
        _MOLE_GITHUB_CLI_CLEAR_REASON="owner cleanup failed"
    fi
    return "$command_status"
}

clean_github_cli_cache() {
    local cache_root
    if ! cache_root=$(mole_github_cli_cache_root); then
        debug_log "Skipping GitHub CLI cache for unsafe XDG_CACHE_HOME: ${XDG_CACHE_HOME:-<unset>}"
        return 0
    fi

    local cache_path="$cache_root/gh"
    [[ -e "$cache_path" || -L "$cache_path" ]] || return 0
    if [[ ! -d "$cache_path" || -L "$cache_path" ]]; then
        debug_log "Skipping GitHub CLI cache because its cache leaf is not a real directory: $cache_path"
        return 0
    fi

    local cache_parent="${cache_path%/*}"
    local physical_parent
    if [[ ! -d "$cache_parent" ]] ||
        ! physical_parent=$(cd "$cache_parent" 2> /dev/null && pwd -P) ||
        [[ -z "$physical_parent" || "$physical_parent" != /* ]]; then
        debug_log "Skipping GitHub CLI cache because its physical parent could not be verified: $cache_path"
        return 0
    fi
    case "$physical_parent" in
        / | "$HOME")
            debug_log "Skipping GitHub CLI cache because its physical parent is unsafe: $physical_parent"
            return 0
            ;;
    esac
    local physical_cache_path="${physical_parent%/}/${cache_path##*/}"

    if ! _mole_snapshot_path_identity "$physical_cache_path" ||
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" != "$physical_parent" ]]; then
        debug_log "Skipping GitHub CLI cache because its identity could not be verified: $cache_path"
        return 0
    fi
    local expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"

    if ! validate_path_for_deletion "$cache_path" > /dev/null 2>&1 ||
        ! validate_path_for_deletion "$physical_cache_path" > /dev/null 2>&1; then
        debug_log "Skipping GitHub CLI cache because its path failed deletion policy: $cache_path"
        return 0
    fi

    local whitelist_path=""
    if is_path_whitelisted "$cache_path"; then
        whitelist_path="$cache_path"
    elif is_path_whitelisted "$physical_cache_path"; then
        whitelist_path="$physical_cache_path"
    fi
    if [[ -n "$whitelist_path" ]]; then
        clean_tool_cache "GitHub CLI cache" "$whitelist_path" :
        return 0
    fi
    if should_protect_path "$cache_path" 2> /dev/null || should_protect_path "$physical_cache_path" 2> /dev/null; then
        debug_log "Skipping protected GitHub CLI cache path: $cache_path"
        return 0
    fi

    command -v gh > /dev/null 2>&1 || return 0
    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard github_cli_process_state "GitHub CLI started"; then
        mole_report_guard_stop "GitHub CLI cache" mole_defer_cleanup_family "GitHub CLI"
        return 0
    fi
    local probe_status=0
    run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        env XDG_CACHE_HOME="$physical_parent" gh config clear-cache --help > /dev/null 2>&1 || probe_status=$?
    if [[ $probe_status -eq 124 || $probe_status -ge 128 ]]; then
        return "$probe_status"
    fi
    if [[ $probe_status -ne 0 ]]; then
        debug_log "Skipping GitHub CLI cache because gh config clear-cache is unavailable"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} GitHub CLI cache · would clean"
        note_activity
        return 0
    fi

    local _MOLE_GITHUB_CLI_CLEAR_REASON=""
    local clear_status=0
    if [[ -t 1 ]]; then
        start_section_spinner "Cleaning GitHub CLI cache..."
    fi
    _run_github_cli_clear_cache_bound "$physical_cache_path" \
        "$expected_parent" "$expected_parent_id" "$expected_target_id" \
        > /dev/null 2>&1 || clear_status=$?
    if [[ -t 1 ]]; then
        stop_section_spinner
    fi

    if [[ $clear_status -eq 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} GitHub CLI cache"
        note_activity
        return 0
    fi
    if [[ $clear_status -eq 124 || $clear_status -ge 128 ]]; then
        return "$clear_status"
    fi

    case "$_MOLE_GITHUB_CLI_CLEAR_REASON" in
        "owner active")
            mole_defer_cleanup_family "GitHub CLI"
            ;;
        "process state unknown" | "cache path changed" | "owner cleanup failed")
            echo -e "  ${GRAY}${ICON_WARNING}${NC} GitHub CLI cache · stopped (${_MOLE_GITHUB_CLI_CLEAR_REASON})"
            note_activity
            ;;
        *)
            echo -e "  ${GRAY}${ICON_WARNING}${NC} GitHub CLI cache · stopped (owner cleanup failed)"
            note_activity
            ;;
    esac
    return 0
}

conda_cache_whitelisted() {
    local root
    for root in "$@"; do
        [[ -n "$root" ]] || continue
        if is_path_whitelisted "$root" 2> /dev/null || is_path_whitelisted "$root/.mole-cache-guard" 2> /dev/null; then
            return 0
        fi
    done
    return 1
}

clean_conda_metadata_caches() {
    local -a conda_pkg_roots=(
        "$HOME/.conda/pkgs"
        "$HOME/anaconda3/pkgs"
        "$HOME/miniconda3/pkgs"
        "$HOME/miniforge3/pkgs"
        "$HOME/mambaforge/pkgs"
    )
    if conda_cache_whitelisted "${conda_pkg_roots[@]}"; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} conda index/tarball/log caches · would skip (whitelist)"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} conda index/tarball/log caches · skipped (whitelist)"
            note_activity
        fi
        return 0
    fi

    local conda_cache_hint="$HOME/.conda/pkgs"
    if command -v conda > /dev/null 2>&1 && run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" conda --version > /dev/null 2>&1; then
        clean_tool_cache "conda index/tarball/log caches" "$conda_cache_hint" \
            run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" conda clean --yes --index-cache --tarballs --logfiles
        note_activity
        return 0
    fi

    local root
    for root in "${conda_pkg_roots[@]}"; do
        [[ -d "$root" ]] || continue
        debug_log "Conda package cache present but conda is unavailable, leaving for manual review: $root"
    done
}

gradle_daemon_running() {
    mole_pgrep_any \
        -f "org.gradle.launcher.daemon" \
        -f "GradleDaemon"
}

# True when a pnpm process is running, or when process state cannot be
# determined (fail closed: skip prune rather than race a live install).
# shellcheck disable=SC2329
pnpm_process_blocks_prune() {
    if ! command -v pgrep > /dev/null 2>&1; then
        return 0
    fi
    # `-x pnpm` only sees the standalone binary. Corepack and npm-installed
    # pnpm run as `node .../pnpm.cjs`, so the guard it was written to be
    # (fail closed while an install is live) never fired for them. Match the
    # invoked program instead, delimited so `pnpm-lock.yaml` in some other
    # process's argv cannot block the prune forever.
    #
    # Capture pgrep's own status: after a failed `if pgrep; then`, $? is the
    # if-statement status (0), not pgrep's 1, which would false-positive block.
    local pgrep_rc=0
    pgrep -f '(^|/)pnpm(\.cjs)?([[:space:]]|$)' > /dev/null 2>&1 || pgrep_rc=$?
    # 0 = running (block), 1 = no match (allow), other = unknown (block).
    [[ $pgrep_rc -ne 1 ]]
}

# Absolute store path without ".." / control characters only.
# shellcheck disable=SC2329
is_safe_pnpm_store_path() {
    local path="${1:-}"
    [[ -n "$path" && "$path" == /* ]] || return 1
    case "$path" in
        *'/../'* | */.. | .. | *$'\n'* | *$'\r'*)
            return 1
            ;;
    esac
    return 0
}

# Emit candidate pnpm binaries already installed locally. Never downloads.
# Order: PATH pnpm first, then mise versioned installs. Callers dedupe by
# resolved store path (issue #1370).
# shellcheck disable=SC2329
list_installed_pnpm_binaries() {
    local bin=""
    if command -v pnpm > /dev/null 2>&1; then
        # type -P resolves only real files; shell-function stubs (tests) fall
        # back to the bare "pnpm" name still reachable on PATH.
        bin=$(type -P pnpm 2> /dev/null || true)
        if [[ -n "$bin" && -x "$bin" ]]; then
            printf '%s\n' "$bin"
        else
            printf '%s\n' "pnpm"
        fi
    fi

    local mise_root="$HOME/.local/share/mise/installs/pnpm"
    if [[ -d "$mise_root" ]]; then
        local version_dir
        for version_dir in "$mise_root"/*; do
            [[ -d "$version_dir" ]] || continue
            if [[ -x "$version_dir/pnpm" ]]; then
                printf '%s\n' "$version_dir/pnpm"
            fi
        done
    fi
}

# Prune every distinct pnpm store generation reachable through an already
# installed matching pnpm binary. Owner command only (plain `store prune`,
# no --force, no raw directory delete). Dedupes by store path so two
# binaries that resolve to the same generation run once (issue #1370).
# shellcheck disable=SC2329
clean_pnpm_stores() {
    local pnpm_default_store="$HOME/Library/pnpm/store"

    if pnpm_process_blocks_prune; then
        debug_log "pnpm process running or process state unknown, skipping store prune"
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} pnpm cache · would skip (pnpm busy)"
            note_activity
        fi
        return 0
    fi

    local -a pnpm_bins=()
    local bin_line
    while IFS= read -r bin_line; do
        [[ -n "$bin_line" ]] || continue
        pnpm_bins+=("$bin_line")
    done < <(list_installed_pnpm_binaries)

    if [[ ${#pnpm_bins[@]} -eq 0 ]]; then
        debug_log "pnpm is unavailable, leaving global pnpm store for manual review: $pnpm_default_store"
        return 0
    fi

    local -a seen_stores=()
    local pruned_any=false
    local pnpm_bin store_path store_seen store_entry
    for pnpm_bin in "${pnpm_bins[@]}"; do
        # Usable binary only; never prompt Corepack to download another major.
        if ! COREPACK_ENABLE_DOWNLOAD_PROMPT=0 run_with_timeout \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$pnpm_bin" --version > /dev/null 2>&1; then
            debug_log "Skipping unusable pnpm binary: $pnpm_bin"
            continue
        fi

        start_section_spinner "Checking pnpm store path..."
        store_path=$(COREPACK_ENABLE_DOWNLOAD_PROMPT=0 run_with_timeout \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$pnpm_bin" store path 2> /dev/null) || store_path=""
        stop_section_spinner

        if ! is_safe_pnpm_store_path "$store_path"; then
            debug_log "Rejecting unsafe or empty pnpm store path from $pnpm_bin: ${store_path:-<empty>}"
            continue
        fi
        store_path="${store_path%/}"

        store_seen=false
        for store_entry in "${seen_stores[@]+"${seen_stores[@]}"}"; do
            if [[ "$store_entry" == "$store_path" ]]; then
                store_seen=true
                break
            fi
        done
        if [[ "$store_seen" == "true" ]]; then
            debug_log "pnpm store already scheduled: $store_path"
            continue
        fi
        seen_stores+=("$store_path")

        COREPACK_ENABLE_DOWNLOAD_PROMPT=0 clean_tool_cache "pnpm cache" "$store_path" \
            run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" \
            env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 "$pnpm_bin" store prune
        pruned_any=true
    done

    if [[ "$pruned_any" != "true" ]]; then
        debug_log "No pruneable pnpm store resolved from installed binaries"
    fi
}

# npm/pnpm/yarn/bun caches.
clean_dev_npm() {
    local npm_default_cache="$HOME/.npm"
    local npm_cache_path="$npm_default_cache"

    if command -v npm > /dev/null 2>&1; then
        start_section_spinner "Checking npm cache path..."
        npm_cache_path=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" npm config get cache 2> /dev/null) || npm_cache_path=""
        stop_section_spinner

        if [[ -z "$npm_cache_path" || "$npm_cache_path" != /* ]]; then
            npm_cache_path="$npm_default_cache"
        fi

        clean_tool_cache "npm cache" "$npm_cache_path" npm cache clean --force
        note_activity
    fi

    # These residual directories are not removed by `npm cache clean --force`
    local -a npm_residual_dirs=("_cacache" "_npx" "_logs" "_prebuilds")
    local -a npm_descriptions=("npm cache directory" "npm npx cache" "npm logs" "npm prebuilds")

    # Clean default npm cache path
    local i
    for i in "${!npm_residual_dirs[@]}"; do
        safe_clean "$npm_default_cache/${npm_residual_dirs[$i]}"/* "${npm_descriptions[$i]}"
    done

    # Normalize paths for comparison (remove trailing slash + resolve symlinked dirs)
    local npm_cache_path_normalized="${npm_cache_path%/}"
    local npm_default_cache_normalized="${npm_default_cache%/}"
    if [[ -d "$npm_cache_path_normalized" ]]; then
        npm_cache_path_normalized=$(cd "$npm_cache_path_normalized" 2> /dev/null && pwd -P) || npm_cache_path_normalized="${npm_cache_path%/}"
    fi
    if [[ -d "$npm_default_cache_normalized" ]]; then
        npm_default_cache_normalized=$(cd "$npm_default_cache_normalized" 2> /dev/null && pwd -P) || npm_default_cache_normalized="${npm_default_cache%/}"
    fi

    # Clean custom npm cache path (if different from default)
    if [[ "$npm_cache_path_normalized" != "$npm_default_cache_normalized" ]]; then
        for i in "${!npm_residual_dirs[@]}"; do
            safe_clean "$npm_cache_path/${npm_residual_dirs[$i]}"/* "${npm_descriptions[$i]} (custom path)"
        done
    fi

    clean_pnpm_stores
    clean_corepack_cache
    local bun_default_cache="$HOME/.bun/install/cache"
    local bun_cache_path="$bun_default_cache"
    local bun_cache_cleaned=false
    local bun_dry_run="${DRY_RUN:-false}"
    if command -v bun > /dev/null 2>&1 && bun --version > /dev/null 2>&1; then
        if [[ -t 1 ]]; then start_section_spinner "Checking bun cache path..."; fi
        bun_cache_path=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" bun pm cache 2> /dev/null) || bun_cache_path=""
        if [[ -t 1 ]]; then stop_section_spinner; fi

        if [[ -z "$bun_cache_path" || "$bun_cache_path" != /* ]]; then
            bun_cache_path="$bun_default_cache"
        fi

        local bun_protected=false
        is_path_whitelisted "$bun_cache_path" && bun_protected=true

        if [[ "$bun_protected" == "true" ]]; then
            if [[ "$bun_dry_run" == "true" ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} bun cache · would skip (whitelist)"
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} bun cache · skipped (whitelist)"
                note_activity
            fi
            bun_cache_cleaned=true
        elif [[ "$bun_dry_run" != "true" ]]; then
            if [[ -t 1 ]]; then
                start_section_spinner "Cleaning bun cache..."
            fi
            if run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" bun pm cache rm > /dev/null 2>&1; then
                bun_cache_cleaned=true
            fi
            if [[ -t 1 ]]; then
                stop_section_spinner
            fi
            if [[ "$bun_cache_cleaned" == "true" ]]; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} bun cache"
                note_activity
            fi
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} bun cache · would clean"
            note_activity
            bun_cache_cleaned=true
        fi

        local bun_cache_path_normalized="${bun_cache_path%/}"
        local bun_default_cache_normalized="${bun_default_cache%/}"
        if [[ -d "$bun_cache_path_normalized" ]]; then
            bun_cache_path_normalized=$(cd "$bun_cache_path_normalized" 2> /dev/null && pwd -P) || bun_cache_path_normalized="${bun_cache_path%/}"
        fi
        if [[ -d "$bun_default_cache_normalized" ]]; then
            bun_default_cache_normalized=$(cd "$bun_default_cache_normalized" 2> /dev/null && pwd -P) || bun_default_cache_normalized="${bun_default_cache%/}"
        fi

        if [[ "$bun_cache_path_normalized" != "$bun_default_cache_normalized" ]]; then
            safe_clean "$bun_default_cache"/* "Orphaned bun cache"
        fi

        # If bun pm cache rm fails, fall back to filesystem cleanup to avoid no-op.
        if [[ "$bun_cache_cleaned" != "true" ]]; then
            safe_clean "$bun_cache_path"/* "Bun cache"
        fi
    else
        safe_clean "$bun_default_cache"/* "Bun cache"
    fi

    note_activity
    safe_clean ~/.tnpm/_cacache/* "tnpm cache directory"
    safe_clean ~/.tnpm/_logs/* "tnpm logs"
    safe_clean ~/.yarn/cache/* "Yarn cache"
    safe_clean ~/Library/Caches/Yarn/* "Yarn v1 cache"
}
# Resolve a cache root to its physical location and prove that it remains a
# descendant of its owner container. Both directories must be ordinary,
# invoking-user-owned directories; user-managed redirect symlinks are kept.
guarded_dev_cache_root_physical_path() {
    local container_root="${1%/}"
    local cache_root="${2%/}"

    [[ "$container_root" == /* && "$cache_root" == /* ]] || return 1
    [[ ! "$container_root" =~ [[:cntrl:]] && ! "$cache_root" =~ [[:cntrl:]] ]] || return 1
    case "$container_root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac
    case "$cache_root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac
    [[ -d "$container_root" && ! -L "$container_root" ]] || return 1
    [[ -d "$cache_root" && ! -L "$cache_root" ]] || return 1

    local physical_container physical_root invoking_uid container_uid root_uid
    physical_container=$(cd -P "$container_root" 2> /dev/null && pwd -P) || return 1
    physical_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || return 1
    [[ "$physical_container" != "/" ]] || return 1
    case "$physical_root" in
        "$physical_container"/*) ;;
        *) return 1 ;;
    esac

    invoking_uid=$(get_invoking_uid 2> /dev/null) || return 1
    [[ "$invoking_uid" =~ ^[0-9]+$ ]] || return 1
    container_uid=$($STAT_BSD -f%u "$physical_container" 2> /dev/null) || return 1
    root_uid=$($STAT_BSD -f%u "$physical_root" 2> /dev/null) || return 1
    [[ "$container_uid" == "$invoking_uid" && "$root_uid" == "$invoking_uid" ]] || return 1
    should_protect_path "$cache_root" && return 1
    should_protect_path "$physical_root" && return 1

    printf '%s\n' "$physical_root"
}

# Compound sink-time guard for rebuildable developer caches. It rechecks both
# process ownership and the container/root/leaf identities immediately before
# safe_remove, so a path swap after discovery cannot redirect deletion.
guarded_dev_cache_cleanup_state() {
    local process_state=0
    "$_MOLE_DEV_CACHE_PROCESS_PROBE" || process_state=$?
    [[ $process_state -eq 1 ]] || return "$process_state"

    local physical_now=""
    physical_now=$(guarded_dev_cache_root_physical_path \
        "$_MOLE_DEV_CACHE_CONTAINER" "$_MOLE_DEV_CACHE_ROOT") || return 2
    [[ "$physical_now" == "$_MOLE_DEV_CACHE_PHYSICAL" ]] || return 2
    _mole_path_matches_identity \
        "$_MOLE_DEV_CACHE_CONTAINER" \
        "$_MOLE_DEV_CACHE_CONTAINER_PARENT" \
        "$_MOLE_DEV_CACHE_CONTAINER_PARENT_ID" \
        "$_MOLE_DEV_CACHE_CONTAINER_TARGET_ID" || return 2
    _mole_path_matches_identity \
        "$_MOLE_DEV_CACHE_ROOT" \
        "$_MOLE_DEV_CACHE_ROOT_PARENT" \
        "$_MOLE_DEV_CACHE_ROOT_PARENT_ID" \
        "$_MOLE_DEV_CACHE_ROOT_TARGET_ID" || return 2

    local guarded_path="${_MOLE_DEV_GUARDED_PATH:-}"
    if [[ -n "$guarded_path" ]]; then
        [[ ! -L "$guarded_path" ]] || return 2
        _mole_snapshot_path_identity "$guarded_path" || return 2
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$physical_now" ]] || return 2

        local leaf_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        local leaf_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        local leaf_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        physical_now=$(guarded_dev_cache_root_physical_path \
            "$_MOLE_DEV_CACHE_CONTAINER" "$_MOLE_DEV_CACHE_ROOT") || return 2
        [[ "$physical_now" == "$_MOLE_DEV_CACHE_PHYSICAL" ]] || return 2
        _mole_path_matches_identity \
            "$_MOLE_DEV_CACHE_ROOT" \
            "$_MOLE_DEV_CACHE_ROOT_PARENT" \
            "$_MOLE_DEV_CACHE_ROOT_PARENT_ID" \
            "$_MOLE_DEV_CACHE_ROOT_TARGET_ID" || return 2

        _MOLE_SAFE_CLEAN_BOUND_PATH="$guarded_path"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$leaf_parent"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$leaf_parent_id"
        _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$leaf_target_id"
    fi
    return 1
}

clean_guarded_dev_cache_root() {
    local container_root="${1%/}"
    local cache_root="${2%/}"
    local process_probe="$3"
    local family="$4"
    local display_name="$5"
    shift 5
    [[ $# -gt 0 ]] || return 0
    mole_cleanup_targets_exist "$@" || return 0

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard "$process_probe" "$family started"; then
        mole_report_guard_stop "$display_name" mole_defer_cleanup_family "$family"
        return 0
    fi

    local physical_root=""
    if ! physical_root=$(guarded_dev_cache_root_physical_path "$container_root" "$cache_root"); then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi

    if ! _mole_snapshot_path_identity "$container_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi
    local container_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local container_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local container_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    if ! _mole_snapshot_path_identity "$cache_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi
    local root_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local root_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local root_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"

    local _MOLE_DEV_CACHE_CONTAINER="$container_root"
    local _MOLE_DEV_CACHE_ROOT="$cache_root"
    local _MOLE_DEV_CACHE_PHYSICAL="$physical_root"
    local _MOLE_DEV_CACHE_CONTAINER_PARENT="$container_parent"
    local _MOLE_DEV_CACHE_CONTAINER_PARENT_ID="$container_parent_id"
    local _MOLE_DEV_CACHE_CONTAINER_TARGET_ID="$container_target_id"
    local _MOLE_DEV_CACHE_ROOT_PARENT="$root_parent"
    local _MOLE_DEV_CACHE_ROOT_PARENT_ID="$root_parent_id"
    local _MOLE_DEV_CACHE_ROOT_TARGET_ID="$root_target_id"
    local _MOLE_DEV_CACHE_PROCESS_PROBE="$process_probe"
    local _MOLE_DEV_PROCESS_GUARD_UNKNOWN_REASON="process or cache path state unknown"
    local clean_rc=0
    _dev_safe_clean_process_guarded \
        guarded_dev_cache_cleanup_state \
        "$family" \
        "$display_name" \
        "$@" \
        "$display_name" || clean_rc=$?
    [[ $clean_rc -eq 1 ]] && return 0
    return "$clean_rc"
}

pyinstaller_build_process_state() {
    mole_pgrep_any \
        -x pyinstaller \
        -f "[p]yinstaller" \
        -f "[P]yInstaller"
}

clean_pyinstaller_bincache() {
    local container_root="$HOME/Library/Application Support"
    local cache_root="$container_root/pyinstaller"
    [[ -d "$cache_root" || -L "$cache_root" ]] || return 0

    local -a candidates=()
    local candidate
    for candidate in "$cache_root"/bincache*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        [[ ! -L "$candidate" ]] || continue
        candidates+=("$candidate")
    done
    [[ ${#candidates[@]} -gt 0 ]] || return 0

    clean_guarded_dev_cache_root \
        "$container_root" \
        "$cache_root" \
        pyinstaller_build_process_state \
        "PyInstaller" \
        "PyInstaller binary cache" \
        "${candidates[@]}"
}

clang_module_cache_process_state() {
    local xcode_state=0
    xcode_build_tooling_process_state || xcode_state=$?
    [[ $xcode_state -eq 1 ]] || return "$xcode_state"
    mole_pgrep_any \
        -x clang \
        -x clangd \
        -x swiftc \
        -x sourcekit-lsp \
        -x SourceKitService
}

clean_clang_module_cache() {
    local darwin_user_cache=""
    local resolver_rc=0
    darwin_user_cache=$(mole_darwin_user_cache_root) || resolver_rc=$?
    if [[ $resolver_rc -ne 0 ]]; then
        [[ $resolver_rc -eq 124 || $resolver_rc -ge 128 ]] && return "$resolver_rc"
        return 0
    fi

    local cache_root="$darwin_user_cache/clang"
    [[ -d "$cache_root" || -L "$cache_root" ]] || return 0
    local -a candidates=()
    local candidate
    for candidate in "$cache_root"/* "$cache_root"/.[!.]* "$cache_root"/..?*; do
        [[ -e "$candidate" || -L "$candidate" ]] || continue
        [[ ! -L "$candidate" ]] || continue
        candidates+=("$candidate")
    done
    [[ ${#candidates[@]} -gt 0 ]] || return 0

    clean_guarded_dev_cache_root \
        "$darwin_user_cache" \
        "$cache_root" \
        clang_module_cache_process_state \
        "Clang" \
        "Clang module cache" \
        "${candidates[@]}"
}

# Python/pip ecosystem caches.
clean_dev_python() {
    # Check pip3 is functional (not just macOS stub that triggers CLT install dialog)
    if command -v pip3 > /dev/null 2>&1 && pip3 --version > /dev/null 2>&1; then
        local pip_cache_path
        pip_cache_path=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" pip3 cache dir 2> /dev/null) || pip_cache_path=""
        if [[ -z "$pip_cache_path" || "$pip_cache_path" != /* ]]; then
            pip_cache_path="$HOME/Library/Caches/pip"
        fi
        clean_tool_cache "pip cache" "$pip_cache_path" bash -c 'pip3 cache purge > /dev/null 2>&1 || true'
        note_activity
    fi
    safe_clean ~/.pyenv/cache/* "pyenv cache"
    safe_clean ~/.cache/poetry/* "Poetry cache"
    # ~/Library/Caches/pypoetry is Poetry's macOS cache root, and its
    # virtualenvs child holds the live interpreters every project points at, so
    # that child is hard-safety whitelisted. Whitelisting a nested path also
    # protects its parent, which takes the whole root out of the generic
    # user-cache sweep and the rebuildable siblings with it. Name those
    # siblings here: artifacts holds built wheels and cache holds repository
    # downloads, both of which Poetry refetches, while virtualenvs stays.
    safe_clean ~/Library/Caches/pypoetry/artifacts/* "Poetry artifacts cache"
    safe_clean ~/Library/Caches/pypoetry/cache/* "Poetry package cache"
    clean_uv_cache
    safe_clean ~/.cache/ruff/* "Ruff cache"
    safe_clean ~/.cache/mypy/* "MyPy cache"
    safe_clean ~/.pytest_cache/* "Pytest cache"
    clean_pyinstaller_bincache
    safe_clean ~/.jupyter/runtime/* "Jupyter runtime cache"
    # Hugging Face, PyTorch, TensorFlow and Weights & Biases keep downloaded
    # model weights, datasets and run artifacts here. Their roots are not
    # blanket caches: Hugging Face's own prune warns that interruption can
    # corrupt its cache, while the other roots mix reusable payloads with run
    # state. Keep all four off the automatic delete path.
    clean_conda_metadata_caches
}

go_cache_process_state() {
    local cache_kind="${1:-GOMODCACHE}"
    # Go documents GOCACHE as safe for multiple local processes. The module
    # cache's whole-root RemoveAll has no equivalent operation-wide lock, so
    # only that root needs the active owner-process gate.
    [[ "$cache_kind" == "GOCACHE" ]] && return 1
    mole_pgrep_any -x go -x gopls
}

# Resolve an owner-reported Go cache root to a stable physical directory. A
# custom Go root is allowed, but broad home/cache parents, protected paths, and
# directories not owned by the invoking user fail closed. A leaf symlink is
# accepted only because the owner command receives the resolved physical root
# and both identities are rebound immediately before it runs.
go_cache_root_physical_path() {
    local cache_root="${1%/}"
    [[ -d "$cache_root" ]] || return 1

    local physical_root=""
    physical_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || return 1
    case "$physical_root" in
        / | "$HOME" | "$HOME/Library" | "$HOME/Library/Caches" | \
            "$HOME/.cache" | "$HOME/go")
            return 1
            ;;
    esac

    validate_path_for_deletion "$cache_root" > /dev/null 2>&1 || return 1
    validate_path_for_deletion "$physical_root" > /dev/null 2>&1 || return 1
    should_protect_path "$cache_root" 2> /dev/null && return 1
    should_protect_path "$physical_root" 2> /dev/null && return 1

    local invoking_uid=""
    local root_uid=""
    invoking_uid=$(get_invoking_uid 2> /dev/null) || return 1
    root_uid=$($STAT_BSD -f%u "$physical_root" 2> /dev/null) || return 1
    [[ "$invoking_uid" =~ ^[0-9]+$ && "$root_uid" == "$invoking_uid" ]] || return 1

    printf '%s\n' "$physical_root"
}

_run_go_cache_clean_bound() {
    local cache_root="$1"
    local physical_root="$2"
    local lexical_parent="$3"
    local lexical_parent_id="$4"
    local lexical_target_id="$5"
    local physical_parent="$6"
    local physical_parent_id="$7"
    local physical_target_id="$8"
    local cache_kind="$9"
    local clean_flag="${10}"
    local owner_dry_run="${11}"

    _MOLE_GO_CACHE_BOUND_REASON=""

    # The entry check only proves the root was not a symlink when the caller
    # looked. A directory swapped for a link afterwards survives the identity
    # comparison below, and `go clean -modcache` would then remove whatever the
    # link resolves to instead of the module root. Re-read the link bit here,
    # at the last hop before the owner command runs.
    if [[ "$cache_kind" == "GOMODCACHE" && -L "$cache_root" ]]; then
        _MOLE_GO_CACHE_BOUND_REASON="symlinked module root"
        return 1
    fi

    local process_state=0
    go_cache_process_state "$cache_kind" || process_state=$?
    if [[ $process_state -eq 0 ]]; then
        _MOLE_GO_CACHE_BOUND_REASON="Go started"
        return 1
    elif [[ $process_state -ne 1 ]]; then
        _MOLE_GO_CACHE_BOUND_REASON="process state unknown"
        return 1
    fi

    if ! _mole_path_matches_identity \
        "$cache_root" "$lexical_parent" "$lexical_parent_id" "$lexical_target_id" ||
        ! _mole_path_matches_identity \
            "$physical_root" "$physical_parent" "$physical_parent_id" "$physical_target_id"; then
        _MOLE_GO_CACHE_BOUND_REASON="cache path state unknown"
        return 1
    fi

    local -a command_args=(env "$cache_kind=$physical_root" go clean)
    if [[ "$owner_dry_run" == "true" ]]; then
        command_args+=(-n)
    fi
    command_args+=("$clean_flag")
    run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" "${command_args[@]}" > /dev/null 2>&1
}

clean_go_cache_root() {
    local cache_root="$1"
    local cache_kind="$2"
    local clean_flag="$3"
    local display_name="$4"
    [[ -e "$cache_root" || -L "$cache_root" ]] || return 0

    # `go clean -modcache` removes the module root itself, not just its
    # contents, so handing it the resolved physical path of a symlinked
    # GOMODCACHE deletes the target directory and leaves the owner's own root a
    # dangling link that the next build cannot use. GOCACHE is safe here
    # because `go clean -cache` empties the cache subdirectories and leaves the
    # root in place.
    if [[ "$cache_kind" == "GOMODCACHE" && -L "$cache_root" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (symlinked module root)"
        note_activity
        return 0
    fi

    local physical_root=""
    if ! physical_root=$(go_cache_root_physical_path "$cache_root"); then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi

    local whitelist_path=""
    if is_path_whitelisted "$cache_root"; then
        whitelist_path="$cache_root"
    elif is_path_whitelisted "$physical_root"; then
        whitelist_path="$physical_root"
    fi
    if [[ -n "$whitelist_path" ]]; then
        clean_tool_cache "$display_name" "$whitelist_path" :
        return 0
    fi

    local process_state=0
    go_cache_process_state "$cache_kind" || process_state=$?
    if [[ $process_state -eq 0 ]]; then
        mole_defer_cleanup_family "Go"
        return 0
    elif [[ $process_state -ne 1 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (process state unknown)"
        note_activity
        return 0
    fi

    if ! _mole_snapshot_path_identity "$cache_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi
    local lexical_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local lexical_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local lexical_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    if ! _mole_snapshot_path_identity "$physical_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path unsafe)"
        note_activity
        return 0
    fi
    local physical_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local physical_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local physical_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"

    local _MOLE_GO_CACHE_BOUND_REASON=""
    local command_status=0
    if [[ "$DRY_RUN" != "true" && -t 1 ]]; then
        start_section_spinner "Cleaning $display_name..."
    fi
    _run_go_cache_clean_bound \
        "$cache_root" "$physical_root" \
        "$lexical_parent" "$lexical_parent_id" "$lexical_target_id" \
        "$physical_parent" "$physical_parent_id" "$physical_target_id" \
        "$cache_kind" "$clean_flag" "$DRY_RUN" || command_status=$?
    if [[ "$DRY_RUN" != "true" && -t 1 ]]; then
        stop_section_spinner
    fi

    if [[ $command_status -eq 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $display_name · would clean"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $display_name"
        fi
        note_activity
        return 0
    fi
    if [[ $command_status -eq 124 || $command_status -ge 128 ]]; then
        return "$command_status"
    fi

    if [[ "$_MOLE_GO_CACHE_BOUND_REASON" == "Go started" ]]; then
        mole_defer_cleanup_family "Go"
    elif [[ -n "$_MOLE_GO_CACHE_BOUND_REASON" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${_MOLE_GO_CACHE_BOUND_REASON})"
        note_activity
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (owner cleanup failed)"
        note_activity
    fi
    return 0
}

# Go explicitly documents both roots as caches and provides the removal
# command. Re-download cost is an acceptable clean tradeoff; the effective
# roots remain independently whitelistable and are rebound at the command
# boundary before the owner command runs.
clean_dev_go() {
    command -v go > /dev/null 2>&1 || return 0

    local go_mod_cache=""
    local go_build_cache=""
    local resolver_rc=0
    go_mod_cache=$(mole_go_cache_root GOMODCACHE) || resolver_rc=$?
    if [[ $resolver_rc -eq 124 || $resolver_rc -ge 128 ]]; then
        return "$resolver_rc"
    fi
    resolver_rc=0
    go_build_cache=$(mole_go_cache_root GOCACHE) || resolver_rc=$?
    if [[ $resolver_rc -eq 124 || $resolver_rc -ge 128 ]]; then
        return "$resolver_rc"
    fi

    if [[ -n "$go_mod_cache" ]]; then
        clean_go_cache_root \
            "$go_mod_cache" GOMODCACHE -modcache "Go module cache" || return $?
    fi
    if [[ -n "$go_build_cache" ]]; then
        clean_go_cache_root \
            "$go_build_cache" GOCACHE -cache "Go build cache" || return $?
    fi
}

get_mise_cache_path() {
    if [[ -n "${MISE_CACHE_DIR:-}" && "${MISE_CACHE_DIR}" == /* ]]; then
        echo "$MISE_CACHE_DIR"
        return 0
    fi

    if command -v mise > /dev/null 2>&1; then
        local mise_cache_path
        mise_cache_path=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" mise cache path 2> /dev/null || echo "")
        if [[ -n "$mise_cache_path" && "$mise_cache_path" == /* ]]; then
            echo "$mise_cache_path"
            return 0
        fi
    fi

    echo "$HOME/Library/Caches/mise"
}

clean_dev_mise() {
    local mise_cache_path
    mise_cache_path=$(get_mise_cache_path)

    if command -v mise > /dev/null 2>&1; then
        if [[ "${DRY_RUN:-false}" != "true" ]]; then
            clean_tool_cache "mise cache" "$mise_cache_path" bash -c 'mise cache clear > /dev/null 2>&1 || true'
            note_activity
        elif is_path_whitelisted "$mise_cache_path"; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} mise cache · would skip (whitelist)"
            note_activity
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} mise cache · would clean"
            note_activity
        fi
    fi

    safe_clean "$mise_cache_path"/* "mise cache"
}
# Resolve a tool home from an optional env value plus default.
# Only absolute paths without ".." / control characters are accepted from
# env; anything else falls back to the default so a poisoned CARGO_HOME
# cannot redirect cleanup (issue #1378, mise-relocated cargo/rustup).
# shellcheck disable=SC2329
resolve_tool_home() {
    local env_value="${1:-}"
    local default_home="$2"

    if [[ -n "$env_value" && "$env_value" == /* ]]; then
        case "$env_value" in
            *'/../'* | */.. | .. | *$'\n'* | *$'\r'*)
                ;;
            *)
                printf '%s\n' "${env_value%/}"
                return 0
                ;;
        esac
    fi
    printf '%s\n' "${default_home%/}"
}

# Cargo and rustc read registry sources throughout builds. Returns the shared
# process tri-state: 0 active, 1 idle, 2 unknown.
rust_build_process_state() {
    mole_pgrep_any \
        -x cargo \
        -x rustc \
        -x rustdoc \
        -x clippy-driver \
        -x cargo-nextest
}

# Resolve a Cargo cache root and prove it remains physically contained by the
# selected CARGO_HOME. The home itself may be symlinked by a version manager,
# but a nested cache root must not escape it.
rust_cache_root_physical_path() {
    local cargo_home="$1"
    local cache_root="$2"
    [[ -d "$cargo_home" && -d "$cache_root" ]] || return 1

    local physical_home physical_root
    physical_home=$(cd -P "$cargo_home" 2> /dev/null && pwd -P) || return 1
    physical_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || return 1
    [[ "$physical_home" != "/" ]] || return 1
    case "$physical_root" in
        "$physical_home"/*)
            printf '%s\n' "$physical_root"
            return 0
            ;;
    esac
    return 1
}

# Combine the process state with the physical root identity for the final
# safe_clean_guarded boundary. Returns 0 active, 1 idle/safe, 2 unknown/changed.
rust_cache_cleanup_state() {
    local process_state=0
    rust_build_process_state || process_state=$?
    [[ $process_state -eq 1 ]] || return "$process_state"

    local physical_now
    physical_now=$(rust_cache_root_physical_path \
        "$_MOLE_RUST_CARGO_HOME" "$_MOLE_RUST_CACHE_ROOT") || return 2
    [[ "$physical_now" == "$_MOLE_RUST_CACHE_PHYSICAL" ]] || return 2

    # Production safe_clean_guarded supplies the exact leaf it is about to
    # remove. Bind that object and its physical parent to safe_remove's final
    # identity check so replacing registry/src (or another Cargo cache root)
    # after this guard cannot redirect the pathname outside CARGO_HOME.
    local guarded_path="${_MOLE_DEV_GUARDED_PATH:-}"
    if [[ -n "$guarded_path" ]]; then
        _mole_snapshot_path_identity "$guarded_path" || return 2
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$physical_now" ]] || return 2

        local physical_after
        physical_after=$(rust_cache_root_physical_path \
            "$_MOLE_RUST_CARGO_HOME" "$_MOLE_RUST_CACHE_ROOT") || return 2
        [[ "$physical_after" == "$physical_now" ]] || return 2

        _MOLE_SAFE_CLEAN_BOUND_PATH="$guarded_path"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
        _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    fi
    return 1
}

clean_rust_dependency_cache_root() {
    local cargo_home="$1"
    local cache_root="$2"
    local display_name="$3"
    [[ -d "$cache_root" ]] || return 0

    local physical_root
    if ! physical_root=$(rust_cache_root_physical_path "$cargo_home" "$cache_root"); then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (cache path leaves CARGO_HOME)"
        note_activity
        return 0
    fi

    local _MOLE_RUST_CARGO_HOME="$cargo_home"
    local _MOLE_RUST_CACHE_ROOT="$cache_root"
    local _MOLE_RUST_CACHE_PHYSICAL="$physical_root"
    local _MOLE_DEV_PROCESS_GUARD_UNKNOWN_REASON="process or cache path state unknown"
    _dev_safe_clean_process_guarded \
        rust_cache_cleanup_state \
        "Rust" \
        "$display_name" \
        "$cache_root"/* \
        "$display_name"
}

# Rust/cargo caches. Honor CARGO_HOME / RUSTUP_HOME when they point at a
# validated absolute path (mise and other version managers relocate these).
# Scope stays redundant download copies only: registry/cache and rustup
# downloads. Keep bin, toolchains, registry/src, registry/index, and git.
#
# registry/src is deliberately excluded. It holds the extracted crate sources
# cargo builds against, so with it present a project still builds after
# registry/cache is emptied; removing both turns every previously working
# offline build into a crates.io round trip. rust-analyzer also reads it
# continuously and is not part of rust_build_process_state, so a deletion
# would break IDE navigation for an editor Mole cannot see. Cargo 1.88+ owns
# age-aware garbage collection for registry sources and git dependencies, so
# Mole does not race that store with a second whole-tree policy.
clean_dev_rust() {
    local cargo_home rustup_home
    cargo_home=$(resolve_tool_home "${CARGO_HOME:-}" "${HOME}/.cargo")
    rustup_home=$(resolve_tool_home "${RUSTUP_HOME:-}" "${HOME}/.rustup")

    if mole_cleanup_targets_exist \
        "${cargo_home}/registry/cache"/*; then
        local rust_state=0
        rust_build_process_state || rust_state=$?
        if [[ $rust_state -eq 0 ]]; then
            mole_defer_cleanup_family "Rust"
        elif [[ $rust_state -eq 1 ]]; then
            clean_rust_dependency_cache_root \
                "$cargo_home" \
                "${cargo_home}/registry/cache" \
                "Rust cargo cache" || return 0
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Rust dependency cache · stopped (process state unknown)"
            note_activity
        fi
    fi
    safe_clean "${rustup_home}/downloads"/* "Rustup downloads cache"
}
# Ruby/gem ecosystem caches (not installed versions).
clean_dev_ruby() {
    safe_clean ~/.rbenv/cache/* "rbenv download cache"
    safe_clean ~/.gem/specs/* "gem spec cache"
    safe_clean ~/.gem/ruby/*/cache/*.gem "gem package cache"
    safe_clean ~/.bundle/cache/* "Ruby Bundler cache"
}
# Perl ecosystem caches (not installed modules).
clean_dev_perl() {
    # ~/.cpan/sources is the distribution store CPAN installs from and reuses
    # across installs, so it stays. Only the throwaway build tree goes.
    safe_clean ~/.cpan/build/* "CPAN build artifacts"
}

# Helper: Check for multiple versions in a directory.
# Args: $1=directory, $2=tool_name, $3=list_command, $4=remove_command
check_multiple_versions() {
    local dir="$1"
    local tool_name="$2"
    local list_cmd="${3:-}"
    local remove_cmd="${4:-}"

    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    local count
    count=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l | tr -d ' ')

    if [[ "$count" -gt 1 ]]; then
        note_activity
        local hint=""
        if [[ -n "$list_cmd" ]]; then
            hint=" ${GRAY}(${list_cmd})${NC}"
        fi
        echo -e "  ${YELLOW}${ICON_REVIEW}${NC} ${tool_name} · ${count} found${hint}"
    fi
}

# Check for multiple Rust toolchains.
check_rust_toolchains() {
    command -v rustup > /dev/null 2>&1 || return 0

    local rustup_home
    rustup_home=$(resolve_tool_home "${RUSTUP_HOME:-}" "${HOME}/.rustup")

    check_multiple_versions \
        "${rustup_home}/toolchains" \
        "Rust toolchains" \
        "rustup toolchain list"
}
# Docker caches (guarded by daemon check).
find_orbstack_data_dir() {
    local candidate
    for candidate in "$HOME"/Library/Group\ Containers/*dev.orbstack/data; do
        [[ -d "$candidate" ]] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

clean_dev_docker() {
    if command -v docker > /dev/null 2>&1; then
        note_activity
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Docker unused data · review with docker system df"
        debug_log "Docker daemon-managed cleanup skipped by default"
    fi

    local orb_data=""
    orb_data=$(find_orbstack_data_dir 2> /dev/null || true)
    if command -v orb > /dev/null 2>&1 || command -v orbctl > /dev/null 2>&1 || [[ -d "$HOME/.orbstack" || -n "$orb_data" ]]; then
        local orb_size=0
        if [[ -n "$orb_data" ]]; then
            local size_rc=0
            orb_size=$(get_path_size_kb "$orb_data" 2> /dev/null) || size_rc=$?
            [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
            [[ $size_rc -eq 0 ]] || return "$size_rc"
            [[ "$orb_size" =~ ^[0-9]+$ ]] || orb_size=0
        fi
        note_activity
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} OrbStack container data · $(bytes_to_human $((orb_size * 1024))) · review with docker system df"
        debug_log "OrbStack daemon-managed data left for manual prune ($orb_size KB)"
    fi
    safe_clean ~/.docker/buildx/cache/* "Docker BuildX cache"
}
# Nix garbage collection.
clean_dev_nix() {
    if command -v nix-collect-garbage > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "Nix garbage collection" "/nix/store" nix-collect-garbage --delete-older-than 30d
        elif is_path_whitelisted "/nix/store"; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Nix garbage collection · would skip (whitelist)"
            note_activity
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Nix garbage collection · would clean"
        fi
        note_activity
    fi
}
# Cloud CLI caches.
clean_dev_cloud() {
    clean_github_cli_cache || return $?
    safe_clean ~/.kube/cache/* "Kubernetes cache"
    safe_clean ~/.local/share/containers/storage/tmp/* "Container storage temp"
    safe_clean ~/.aws/cli/cache/* "AWS CLI cache"
    safe_clean ~/.config/gcloud/logs/* "Google Cloud logs"
    safe_clean ~/.azure/logs/* "Azure CLI logs"
}
# Frontend build caches.
clean_dev_frontend() {
    safe_clean ~/.cache/typescript/* "TypeScript cache"
    safe_clean ~/.cache/electron/* "Electron cache"
    safe_clean ~/.cache/node-gyp/* "node-gyp cache"
    safe_clean ~/.node-gyp/* "node-gyp build cache"
    safe_clean ~/.turbo/cache/* "Turbo cache"
    safe_clean ~/.vite/cache/* "Vite cache"
    safe_clean ~/.cache/vite/* "Vite global cache"
    safe_clean ~/.cache/webpack/* "Webpack cache"
    safe_clean ~/.parcel-cache/* "Parcel cache"
    safe_clean ~/.cache/eslint/* "ESLint cache"
    safe_clean ~/.cache/prettier/* "Prettier cache"
}
# Check for multiple Android NDK versions.
check_android_ndk() {
    check_multiple_versions \
        "$HOME/Library/Android/sdk/ndk" \
        "Android NDK versions" \
        "Android Studio → SDK Manager"
}

clean_xcode_documentation_cache() {
    local doc_cache_root="${MOLE_XCODE_DOCUMENTATION_CACHE_DIR:-/Library/Developer/Xcode/DocumentationCache}"
    [[ -d "$doc_cache_root" ]] || return 0

    local -a index_entries=()
    while IFS= read -r -d '' entry; do
        [[ ! -L "$entry" ]] || continue
        index_entries+=("$entry")
    done < <(command find "$doc_cache_root" -mindepth 1 -maxdepth 1 \( -name "DeveloperDocumentation.index" -o -name "DeveloperDocumentation*.index" \) -print0 2> /dev/null)

    if [[ ${#index_entries[@]} -le 1 ]]; then
        return 0
    fi

    local -a index_mtimes=()
    local entry mtime
    for entry in "${index_entries[@]}"; do
        mtime=$(stat -f%m "$entry" 2> /dev/null || echo "0")
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        index_mtimes+=("$mtime")
    done

    # Keep pathnames byte-exact; index names can legally contain newlines.
    local i j key_mtime key_entry
    for ((i = 1; i < ${#index_entries[@]}; i++)); do
        key_entry="${index_entries[$i]}"
        key_mtime="${index_mtimes[$i]}"
        j=$((i - 1))
        while [[ $j -ge 0 && ${index_mtimes[$j]} -lt $key_mtime ]]; do
            index_entries[j + 1]="${index_entries[$j]}"
            index_mtimes[j + 1]="${index_mtimes[$j]}"
            j=$((j - 1))
        done
        index_entries[j + 1]="$key_entry"
        index_mtimes[j + 1]="$key_mtime"
    done

    local -a stale_entries=()
    local idx=0
    for entry in "${index_entries[@]}"; do
        if [[ $idx -eq 0 ]]; then
            idx=$((idx + 1))
            continue
        fi
        stale_entries+=("$entry")
        idx=$((idx + 1))
    done

    if [[ ${#stale_entries[@]} -eq 0 ]]; then
        return 0
    fi

    # Form the same eligible set as the deletion loop before consulting
    # process state. Protected-only work must stay silent instead of promising
    # an Xcode defer that can never be cleaned.
    local -a eligible_stale_entries=()
    local pre_skipped_count=0
    for entry in "${stale_entries[@]}"; do
        [[ ! -L "$entry" ]] || continue
        if should_protect_path "$entry" || is_path_whitelisted "$entry" || holds_compiled_model_cache "$entry"; then
            pre_skipped_count=$((pre_skipped_count + 1))
            continue
        fi
        eligible_stale_entries+=("$entry")
    done
    [[ ${#eligible_stale_entries[@]} -gt 0 ]] || return 0
    stale_entries=("${eligible_stale_entries[@]}")

    local process_state=0
    _xcode_xctest_devices_process_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $pre_skipped_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · skipped ${pre_skipped_count} protected items"
            note_activity
        fi
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        _xcode_safe_clean_guarded \
            _xcode_delete_guard_allows \
            "Xcode documentation cache" \
            "${stale_entries[@]}" \
            "Xcode documentation cache (old indexes)" || return 0
        return 0
    fi

    if ! has_sudo_session; then
        if ! ensure_sudo_session "Cleaning Xcode documentation cache requires admin access"; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · skipped (sudo denied)"
            note_activity
            return 0
        fi
    fi

    local removed_count=0
    local removed_size_kb=0
    local skipped_count=$pre_skipped_count
    local failed_count=0
    local stop_reason=""
    local stale_entry
    for stale_entry in "${stale_entries[@]}"; do
        if should_protect_path "$stale_entry" || is_path_whitelisted "$stale_entry" || holds_compiled_model_cache "$stale_entry"; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        local stale_size_kb=0
        stale_size_kb=$(_sim_runtime_size_kb "$stale_entry")

        process_state=0
        _xcode_xctest_devices_process_running || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            stop_reason="Xcode or build tools started"
            [[ $process_state -eq 2 ]] && stop_reason="process state unknown"
            break
        fi
        if safe_sudo_remove "$stale_entry" "$stale_size_kb"; then
            removed_count=$((removed_count + 1))
            removed_size_kb=$((removed_size_kb + stale_size_kb))
        else
            failed_count=$((failed_count + 1))
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode documentation cache · removed ${removed_count} old indexes"
        files_cleaned=$((${files_cleaned:-0} + removed_count))
        total_size_cleaned=$((${total_size_cleaned:-0} + removed_size_kb))
        total_items=$((${total_items:-0} + 1))
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · skipped ${skipped_count} protected items"
        fi
        if [[ $failed_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · could not remove ${failed_count} old indexes"
        fi
        note_activity
    elif [[ $failed_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · could not remove ${failed_count} old indexes"
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · skipped ${skipped_count} protected items"
        fi
        note_activity
    elif [[ $skipped_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · skipped ${skipped_count} protected items"
        note_activity
    elif [[ -z "$stop_reason" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · no items removed"
        note_activity
    fi
    if [[ -n "$stop_reason" ]]; then
        if [[ "$stop_reason" == "process state unknown" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · stopped (${stop_reason})"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
    fi
}

_MOLE_XCODE_PROCESS_MATCH=""

# Return 0 when a foreground owner is active, 1 when none is present, and 2
# when the process state cannot be established. Short-lived build and simulator
# tools stay guarded because they can mutate these caches before a device is
# fully booted. CoreSimulatorService and simdiskimaged are
# launchd-managed services that can remain alive after Simulator exits, so
# their existence alone is not evidence that a simulator is active (#1319).
_coresimulator_cache_process_running() {
    local match_mode match_pattern match_label probe_status
    _MOLE_XCODE_PROCESS_MATCH=""

    while IFS='|' read -r match_mode match_pattern match_label; do
        [[ -n "$match_pattern" ]] || continue
        if pgrep "$match_mode" "$match_pattern" > /dev/null 2>&1; then
            _MOLE_XCODE_PROCESS_MATCH="$match_label"
            debug_log "CoreSimulator process detected: $match_label"
            return 0
        else
            probe_status=$?
        fi
        if [[ $probe_status -ne 1 ]]; then
            debug_log "CoreSimulator process check failed: $match_label (exit=$probe_status)"
            return 2
        fi
    done << 'EOF'
-x|Xcode|Xcode
-x|Simulator|Simulator
-x|xcodebuild|xcodebuild
-x|xctest|xctest
-x|XCTRunner|XCTRunner
-x|simctl|simctl
EOF

    return 1
}

# Return 0 when simctl reports a booted device, 1 for a valid empty result, and
# 2 when the active state cannot be established. Unknown must fail closed
# before system CoreSimulator or XCTest data is removed.
_coresimulator_booted_device_state() {
    if [[ "$_MOLE_SIMCTL_RESOLUTION_STATUS" != "ready" ]]; then
        if ! command -v xcrun > /dev/null 2>&1 || ! _resolve_simctl_developer_dir; then
            debug_log "Unable to resolve simctl for booted-device check"
            return 2
        fi
    fi

    local booted_output=""
    local probe_status=0
    booted_output=$(_run_simctl "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" list devices booted -j 2> /dev/null) || probe_status=$?
    if [[ $probe_status -ne 0 ]]; then
        debug_log "Booted simulator probe failed (exit=$probe_status)"
        return 2
    fi
    if [[ "$booted_output" != *'"devices"'* ]]; then
        debug_log "Booted simulator probe returned an unexpected response"
        return 2
    fi
    if [[ "$booted_output" == *'"udid"'* ]]; then
        _MOLE_XCODE_PROCESS_MATCH="booted simulator"
        debug_log "CoreSimulator active state detected: booted simulator"
        return 0
    fi

    return 1
}

# Bracket the booted-device probe with the same process check on both sides.
# That structured probe can take several seconds, which is long enough for
# simctl or xcodebuild to start; without the second check the guard would
# authorize a deletion on evidence gathered before the build began.
# Returns the probe tri-state: 0 running, 1 not running, 2 unknown.
_probe_simulator_activity() {
    local process_probe="$1"
    local state=0
    "$process_probe" || state=$?
    [[ $state -eq 1 ]] || return "$state"

    state=0
    _coresimulator_booted_device_state || state=$?
    [[ $state -eq 1 ]] || return "$state"

    state=0
    "$process_probe" || state=$?
    return "$state"
}

_coresimulator_activity_state() {
    _probe_simulator_activity _coresimulator_cache_process_running
}

_xcode_xctest_devices_process_running() {
    local match_mode match_pattern match_label probe_status=0

    xcode_build_tooling_process_state || probe_status=$?
    if [[ $probe_status -eq 0 ]]; then
        _MOLE_XCODE_PROCESS_MATCH="Xcode/build tooling"
        return 0
    fi
    [[ $probe_status -eq 1 ]] || return 2

    probe_status=0
    if _coresimulator_cache_process_running; then
        return 0
    else
        probe_status=$?
    fi
    [[ $probe_status -eq 1 ]] || return 2

    while IFS='|' read -r match_mode match_pattern match_label; do
        [[ -n "$match_pattern" ]] || continue
        if pgrep "$match_mode" "$match_pattern" > /dev/null 2>&1; then
            _MOLE_XCODE_PROCESS_MATCH="$match_label"
            debug_log "XCTest process detected: $match_label"
            return 0
        else
            probe_status=$?
        fi
        if [[ $probe_status -ne 1 ]]; then
            debug_log "XCTest process check failed: $match_label (exit=$probe_status)"
            return 2
        fi
    done << 'EOF'
-f|com.apple.dt.XCTest|com.apple.dt.XCTest
-f|XCTest|XCTest
EOF

    return 1
}

_xcode_delete_guard_allows() {
    mole_clean_process_guard _xcode_xctest_devices_process_running "Xcode or build tools started"
}

_coresimulator_delete_guard_allows() {
    mole_clean_process_guard _coresimulator_activity_state "CoreSimulator started"
}

_xctest_devices_activity_state() {
    _probe_simulator_activity _xcode_xctest_devices_process_running
}

_xctest_devices_delete_guard_allows() {
    mole_clean_process_guard _xctest_devices_activity_state "Xcode, XCTest, or Simulator started"
}

_dev_process_delete_guard_allows() {
    # safe_clean_guarded passes the leaf currently at its deletion boundary.
    # Keep it in dynamic scope so compound probes such as the Cargo root guard
    # can bind that exact object without changing ordinary process probes.
    local _MOLE_DEV_GUARDED_PATH="${1:-}"
    mole_clean_process_guard \
        "$_MOLE_DEV_PROCESS_GUARD_PROBE" \
        "$_MOLE_DEV_PROCESS_GUARD_FAMILY started" \
        "${_MOLE_DEV_PROCESS_GUARD_UNKNOWN_REASON:-process state unknown}"
}

_dev_report_process_guard_stop() {
    local display_name="$1"
    local family="$2"
    local reason="$3"

    if [[ "$reason" == "process state unknown" || "$reason" == "process or cache path state unknown" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${reason})"
        note_activity
    else
        mole_defer_cleanup_family "$family"
    fi
}

# Bind a tri-state process probe to safe_clean's post-size boundary. The local
# guard state is intentionally dynamic so Bash 3.2 callbacks can read it.
_dev_safe_clean_process_guarded() {
    local probe="$1"
    local family="$2"
    local display_name="$3"
    shift 3
    local _MOLE_DEV_PROCESS_GUARD_PROBE="$probe"
    local _MOLE_DEV_PROCESS_GUARD_FAMILY="$family"
    local _MOLE_CLEAN_GUARD_REASON="${family} started"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! _dev_process_delete_guard_allows; then
            _dev_report_process_guard_stop "$display_name" "$family" "$_MOLE_CLEAN_GUARD_REASON"
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded _dev_process_delete_guard_allows "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        _dev_report_process_guard_stop "$display_name" "$family" "$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi
    return "$guarded_rc"
}

_dev_clean_service_worker_process_guarded() {
    local probe="$1"
    local family="$2"
    local display_name="$3"
    local browser_name="$4"
    local cache_path="$5"
    local _MOLE_DEV_PROCESS_GUARD_PROBE="$probe"
    local _MOLE_DEV_PROCESS_GUARD_FAMILY="$family"
    local _MOLE_CLEAN_GUARD_REASON="${family} started"
    local guarded_rc=0

    clean_service_worker_cache \
        "$browser_name" \
        "$cache_path" \
        _dev_process_delete_guard_allows || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        _dev_report_process_guard_stop "$display_name" "$family" "$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi
    return "$guarded_rc"
}

# Production safe_clean_guarded binds the process probe to its internal
# post-size deletion boundary. Unit-level callers that source this module
# without bin/clean.sh keep the historical safe_clean surface.
_xcode_safe_clean_guarded() {
    local delete_guard="$1"
    local display_name="$2"
    shift 2
    local _MOLE_CLEAN_GUARD_REASON="process state changed"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! "$delete_guard"; then
            if [[ "$_MOLE_CLEAN_GUARD_REASON" == "process state unknown" ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${_MOLE_CLEAN_GUARD_REASON})"
                note_activity
            elif [[ "$delete_guard" == "_coresimulator_delete_guard_allows" ]]; then
                mole_defer_cleanup_family "Simulator"
            else
                mole_defer_cleanup_family "Xcode"
            fi
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded "$delete_guard" "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        if [[ "$_MOLE_CLEAN_GUARD_REASON" == "process state unknown" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${_MOLE_CLEAN_GUARD_REASON})"
            note_activity
        elif [[ "$delete_guard" == "_coresimulator_delete_guard_allows" ]]; then
            mole_defer_cleanup_family "Simulator"
        else
            mole_defer_cleanup_family "Xcode"
        fi
        return 1
    fi
    return "$guarded_rc"
}

clean_xcode_xctest_devices() {
    local xctest_devices_dir="${MOLE_XCODE_XCTEST_DEVICES_DIR:-$HOME/Library/Developer/XCTestDevices}"
    [[ -d "$xctest_devices_dir" ]] || return 0

    # Preserve safe_clean's skip accounting while checking eligibility before
    # the process gate. This avoids a false defer for policy-excluded roots.
    local policy_reason=""
    if should_protect_path "$xctest_devices_dir"; then
        policy_reason="protected"
    elif is_path_whitelisted "$xctest_devices_dir"; then
        policy_reason="whitelist"
    elif declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$xctest_devices_dir"; then
        policy_reason="compiled model cache"
    fi
    if [[ -n "$policy_reason" ]]; then
        if declare -p whitelist_skipped_count > /dev/null 2>&1; then
            whitelist_skipped_count=$((whitelist_skipped_count + 1))
        fi
        if declare -f log_operation > /dev/null 2>&1; then
            log_operation "clean" "SKIPPED" "$xctest_devices_dir" "$policy_reason"
        fi
        return 0
    fi

    local process_state=0
    _xctest_devices_activity_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode XCTestDevices · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
        return 0
    fi

    # Test clones accumulate one UUID directory per test run, so the root
    # grows without bound and a single-tree removal can exceed the per-item
    # removal budget after deleting only part of it. Delete each entry
    # separately so the budget, sink guard, and sizing apply per clone. The
    # root itself stays: Xcode recreates clones inside it.
    local -a device_entries=()
    local device_entry
    while IFS= read -r -d '' device_entry; do
        device_entries+=("$device_entry")
    done < <(command find "$xctest_devices_dir" -mindepth 1 -maxdepth 1 -print0 2> /dev/null)
    [[ ${#device_entries[@]} -gt 0 ]] || return 0

    _xcode_safe_clean_guarded \
        _xctest_devices_delete_guard_allows \
        "Xcode XCTestDevices" \
        "${device_entries[@]}" \
        "Xcode XCTestDevices test data" || true
}

clean_xcode_system_coresimulator_caches() {
    local cache_root="${MOLE_XCODE_SYSTEM_CORESIMULATOR_CACHE_DIR:-/Library/Developer/CoreSimulator/Caches}"
    [[ -d "$cache_root" ]] || return 0

    local -a cache_entries=()
    local entry
    while IFS= read -r -d '' entry; do
        cache_entries+=("$entry")
    done < <(command find "$cache_root" -mindepth 1 -maxdepth 1 -print0 2> /dev/null)

    [[ ${#cache_entries[@]} -gt 0 ]] || return 0

    # Match the privileged removal loop before the process gate. Otherwise a
    # protected-only cache root is incorrectly advertised as deferred work.
    local -a eligible_cache_entries=()
    local pre_skipped_count=0
    for entry in "${cache_entries[@]}"; do
        [[ ! -L "$entry" ]] || continue
        if should_protect_path "$entry" || is_path_whitelisted "$entry" || holds_compiled_model_cache "$entry"; then
            pre_skipped_count=$((pre_skipped_count + 1))
            continue
        fi
        eligible_cache_entries+=("$entry")
    done
    [[ ${#eligible_cache_entries[@]} -gt 0 ]] || return 0
    cache_entries=("${eligible_cache_entries[@]}")

    local process_state=0
    _coresimulator_activity_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode Simulator system cache · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Simulator"
        fi
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        local total_size_kb=0
        local cleanable_count=0
        local stop_reason=""
        for entry in "${cache_entries[@]}"; do
            process_state=0
            _coresimulator_activity_state || process_state=$?
            if [[ $process_state -ne 1 ]]; then
                stop_reason="CoreSimulator started"
                [[ $process_state -eq 2 ]] && stop_reason="process state unknown"
                break
            fi
            if should_protect_path "$entry" || is_path_whitelisted "$entry" || holds_compiled_model_cache "$entry"; then
                continue
            fi
            local entry_size_kb=""
            local size_rc=0
            entry_size_kb=$(get_path_size_kb "$entry" 2> /dev/null) || size_rc=$?
            [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
            [[ $size_rc -eq 0 ]] || return "$size_rc"
            [[ "$entry_size_kb" =~ ^[0-9]+$ ]] || entry_size_kb=0

            process_state=0
            _coresimulator_activity_state || process_state=$?
            if [[ $process_state -ne 1 ]]; then
                stop_reason="CoreSimulator started"
                [[ $process_state -eq 2 ]] && stop_reason="process state unknown"
                break
            fi
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$entry" "$entry_size_kb" 1 true || continue
            fi
            total_size_kb=$((total_size_kb + entry_size_kb))
            cleanable_count=$((cleanable_count + 1))
        done
        if [[ "$cleanable_count" -gt 0 ]]; then
            local total_size_human
            total_size_human=$(bytes_to_human "$((total_size_kb * 1024))")
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Xcode Simulator system cache · would remove ${cleanable_count} entries (${total_size_human})"
            note_activity
        fi
        if [[ -n "$stop_reason" ]]; then
            if [[ "$stop_reason" == "process state unknown" ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode Simulator system cache · stopped (${stop_reason})"
                note_activity
            else
                mole_defer_cleanup_family "Simulator"
            fi
        fi
        return 0
    fi

    if ! has_sudo_session; then
        if ! ensure_sudo_session "Cleaning Xcode Simulator system cache requires admin access"; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Xcode Simulator system cache · skipped (sudo denied)"
            note_activity
            return 0
        fi
    fi

    local removed_count=0
    local removed_size_kb=0
    local skipped_count=$pre_skipped_count
    local failed_count=0
    local stop_reason=""
    for entry in "${cache_entries[@]}"; do
        process_state=0
        _coresimulator_activity_state || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            stop_reason="CoreSimulator started"
            [[ $process_state -eq 2 ]] && stop_reason="process state unknown"
            break
        fi
        if should_protect_path "$entry" || is_path_whitelisted "$entry" || holds_compiled_model_cache "$entry"; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        local entry_size_kb=""
        local size_rc=0
        entry_size_kb=$(get_path_size_kb "$entry" 2> /dev/null) || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        [[ "$entry_size_kb" =~ ^[0-9]+$ ]] || entry_size_kb=0

        # A bounded size probe can still overlap Simulator startup. Recheck
        # immediately before the privileged deletion sink.
        process_state=0
        _coresimulator_activity_state || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            stop_reason="CoreSimulator started"
            [[ $process_state -eq 2 ]] && stop_reason="process state unknown"
            break
        fi
        if safe_sudo_remove "$entry" "$entry_size_kb"; then
            removed_count=$((removed_count + 1))
            removed_size_kb=$((removed_size_kb + entry_size_kb))
        else
            failed_count=$((failed_count + 1))
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        local removed_human
        removed_human=$(bytes_to_human "$((removed_size_kb * 1024))")
        local line_color
        line_color=$(cleanup_result_color_kb "$removed_size_kb")
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode Simulator system cache · removed ${removed_count} (${line_color}${removed_human}${NC}), skipped ${skipped_count} protected"
        else
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode Simulator system cache · removed ${removed_count} (${line_color}${removed_human}${NC})"
        fi
        if [[ $failed_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode Simulator system cache · could not remove ${failed_count} entries"
        fi
        files_cleaned=$((${files_cleaned:-0} + removed_count))
        total_size_cleaned=$((${total_size_cleaned:-0} + removed_size_kb))
        total_items=$((${total_items:-0} + 1))
        note_activity
    elif [[ $failed_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode Simulator system cache · could not remove ${failed_count} entries"
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Xcode Simulator system cache · skipped ${skipped_count} protected"
        fi
        note_activity
    elif [[ $skipped_count -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Xcode Simulator system cache · skipped ${skipped_count} protected, none removed"
        note_activity
    fi
    if [[ -n "$stop_reason" ]]; then
        if [[ "$stop_reason" == "process state unknown" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode Simulator system cache · stopped (${stop_reason})"
            note_activity
        else
            mole_defer_cleanup_family "Simulator"
        fi
    fi
}

# Clean old Xcode DeviceSupport versions, keeping the most recent ones.
# Each version holds debug symbols (1-3 GB) for a specific iOS/watchOS/tvOS version.
# Symbols regenerate automatically when a device running that version is connected.
# Args: $1=directory path, $2=display name (e.g. "iOS DeviceSupport")
clean_xcode_device_support() {
    local ds_dir="$1"
    local display_name="$2"
    local keep_count="${MOLE_XCODE_DEVICE_SUPPORT_KEEP:-2}"
    local -a preview_stale_dirs=()
    [[ "$keep_count" =~ ^[0-9]+$ ]] || keep_count=2

    [[ -d "$ds_dir" ]] || return 0

    local candidate
    local -a preflight_dirs=()
    while IFS= read -r -d '' candidate; do
        preflight_dirs+=("$candidate")
    done < <(command find "$ds_dir" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null || true)
    local has_inner_cleanup_target=false
    mole_cleanup_targets_exist \
        "$ds_dir"/*/Symbols/System/Library/Caches/* \
        "$ds_dir"/*.log && has_inner_cleanup_target=true

    local has_stale_cleanup_target=false
    if [[ ${#preflight_dirs[@]} -gt $keep_count ]]; then
        local -a preflight_mtimes=()
        local preflight_mtime=""
        for candidate in "${preflight_dirs[@]}"; do
            if ! preflight_mtime=$(stat -f%m "$candidate" 2> /dev/null) || [[ ! "$preflight_mtime" =~ ^[0-9]+$ ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (metadata unavailable)"
                note_activity
                return 0
            fi
            preflight_mtimes+=("$preflight_mtime")
        done

        local -a preflight_pending_dirs=("${preflight_dirs[@]}")
        local -a preflight_pending_mtimes=("${preflight_mtimes[@]}")
        local preflight_rank=0 preflight_index preflight_best_index
        while [[ ${#preflight_pending_dirs[@]} -gt 0 ]]; do
            preflight_best_index=0
            for ((preflight_index = 1; preflight_index < ${#preflight_pending_dirs[@]}; preflight_index++)); do
                if [[ ${preflight_pending_mtimes[$preflight_index]} -gt ${preflight_pending_mtimes[$preflight_best_index]} ]]; then
                    preflight_best_index=$preflight_index
                fi
            done
            if [[ $preflight_rank -ge $keep_count ]] &&
                ! should_protect_path "${preflight_pending_dirs[$preflight_best_index]}" &&
                ! is_path_whitelisted "${preflight_pending_dirs[$preflight_best_index]}" &&
                ! holds_compiled_model_cache "${preflight_pending_dirs[$preflight_best_index]}"; then
                has_stale_cleanup_target=true
                break
            fi
            preflight_rank=$((preflight_rank + 1))
            unset "preflight_pending_dirs[$preflight_best_index]" "preflight_pending_mtimes[$preflight_best_index]"
            if [[ ${#preflight_pending_dirs[@]} -gt 0 ]]; then
                preflight_pending_dirs=("${preflight_pending_dirs[@]}")
                preflight_pending_mtimes=("${preflight_pending_mtimes[@]}")
            fi
        done
    fi

    if [[ "$has_stale_cleanup_target" != "true" && "$has_inner_cleanup_target" != "true" ]]; then
        return 0
    fi

    # DeviceSupport contains symbols used by active builds, tests, and device
    # debugging. Keep every version when any Xcode tooling is active.
    local process_state=0
    _xcode_xctest_devices_process_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
        return 0
    fi

    # Collect version directories (each is a platform version like "17.5 (21F79)")
    local -a version_dirs=()
    local scan_file=""
    scan_file=$(mktemp "${TMPDIR:-/tmp}/mole-device-support.XXXXXX") || {
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (scan unavailable)"
        note_activity
        return 0
    }
    if ! command find "$ds_dir" -mindepth 1 -maxdepth 1 -print0 > "$scan_file" 2> /dev/null; then
        rm -f "$scan_file" # SAFE: exact temporary file created by mktemp above
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (scan unavailable)"
        note_activity
        return 0
    fi
    while IFS= read -r -d '' entry; do
        # Skip non-directories (e.g. .log files at the top level)
        [[ -d "$entry" ]] || continue
        version_dirs+=("$entry")
    done < "$scan_file"
    rm -f "$scan_file" # SAFE: exact temporary file created by mktemp above

    if [[ ${#version_dirs[@]} -gt 0 ]]; then
        local -a version_mtimes=()
        local mtime=""
        for entry in "${version_dirs[@]}"; do
            if ! mtime=$(stat -f%m "$entry" 2> /dev/null) || [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (metadata unavailable)"
                note_activity
                return 0
            fi
            version_mtimes+=("$mtime")
        done

        # Sort by modification time (most recent first) without serializing
        # pathnames through newline-delimited text. DeviceSupport is writable by
        # the invoking user, so even unusual names must stay byte-exact.
        local -a sorted_dirs=()
        local -a pending_dirs=("${version_dirs[@]}")
        local -a pending_mtimes=("${version_mtimes[@]}")
        local index best_index
        while [[ ${#pending_dirs[@]} -gt 0 ]]; do
            best_index=0
            for ((index = 1; index < ${#pending_dirs[@]}; index++)); do
                if [[ ${pending_mtimes[$index]} -gt ${pending_mtimes[$best_index]} ]]; then
                    best_index=$index
                fi
            done
            sorted_dirs+=("${pending_dirs[$best_index]}")
            unset "pending_dirs[$best_index]" "pending_mtimes[$best_index]"
            if [[ ${#pending_dirs[@]} -gt 0 ]]; then
                pending_dirs=("${pending_dirs[@]}")
                pending_mtimes=("${pending_mtimes[@]}")
            fi
        done

        # Get stale versions (everything after keep_count)
        local -a stale_dirs=("${sorted_dirs[@]:$keep_count}")

        if [[ ${#stale_dirs[@]} -gt 0 ]]; then
            local stale_size_kb=0 entry_size_kb
            local stale_size_human=""

            if [[ "$DRY_RUN" == "true" ]]; then
                local dry_run_count=0
                local dry_stop_reason=""
                stale_size_kb=0
                for stale_entry in "${stale_dirs[@]}"; do
                    process_state=0
                    _xcode_xctest_devices_process_running || process_state=$?
                    if [[ $process_state -ne 1 ]]; then
                        dry_stop_reason="Xcode or build tools started"
                        [[ $process_state -eq 2 ]] && dry_stop_reason="process state unknown"
                        break
                    fi
                    if should_protect_path "$stale_entry" || is_path_whitelisted "$stale_entry" || holds_compiled_model_cache "$stale_entry"; then
                        continue
                    fi
                    local size_rc=0
                    entry_size_kb=$(get_path_size_kb "$stale_entry" 2> /dev/null) || size_rc=$?
                    [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
                    [[ $size_rc -eq 0 ]] || return "$size_rc"
                    [[ "$entry_size_kb" =~ ^[0-9]+$ ]] || entry_size_kb=0

                    process_state=0
                    _xcode_xctest_devices_process_running || process_state=$?
                    if [[ $process_state -ne 1 ]]; then
                        dry_stop_reason="Xcode or build tools started"
                        [[ $process_state -eq 2 ]] && dry_stop_reason="process state unknown"
                        break
                    fi
                    if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                        record_dry_run_cleanup_target "$stale_entry" "$entry_size_kb" 1 true || continue
                    fi
                    preview_stale_dirs+=("$stale_entry")
                    stale_size_kb=$((stale_size_kb + entry_size_kb))
                    dry_run_count=$((dry_run_count + 1))
                done
                if [[ "$dry_run_count" -gt 0 ]]; then
                    stale_size_human=$(bytes_to_human "$((stale_size_kb * 1024))")
                    echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} ${display_name} · would remove ${dry_run_count} old versions (${stale_size_human}), keeping ${keep_count} most recent"
                    note_activity
                fi
                if [[ -n "$dry_stop_reason" ]]; then
                    if [[ "$dry_stop_reason" == "process state unknown" ]]; then
                        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${dry_stop_reason})"
                        note_activity
                    else
                        mole_defer_cleanup_family "Xcode"
                    fi
                    return 0
                fi
            else
                # Remove old versions
                local removed_count=0
                local removed_size_kb=0
                local stop_reason=""
                for stale_entry in "${stale_dirs[@]}"; do
                    process_state=0
                    _xcode_xctest_devices_process_running || process_state=$?
                    if [[ $process_state -ne 1 ]]; then
                        stop_reason="Xcode or build tools started"
                        [[ $process_state -eq 2 ]] && stop_reason="process state unknown"
                        break
                    fi
                    if should_protect_path "$stale_entry" || is_path_whitelisted "$stale_entry" || holds_compiled_model_cache "$stale_entry"; then
                        continue
                    fi
                    local size_rc=0
                    entry_size_kb=$(get_path_size_kb "$stale_entry" 2> /dev/null) || size_rc=$?
                    [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
                    [[ $size_rc -eq 0 ]] || return "$size_rc"
                    [[ "$entry_size_kb" =~ ^[0-9]+$ ]] || entry_size_kb=0

                    # The size probe may consume the full disk-verification
                    # budget. Bind authorization to the deletion boundary by
                    # checking active Xcode tooling again after it completes.
                    process_state=0
                    _xcode_xctest_devices_process_running || process_state=$?
                    if [[ $process_state -ne 1 ]]; then
                        stop_reason="Xcode or build tools started"
                        [[ $process_state -eq 2 ]] && stop_reason="process state unknown"
                        break
                    fi
                    if safe_remove "$stale_entry" "true" "$entry_size_kb"; then
                        removed_count=$((removed_count + 1))
                        removed_size_kb=$((removed_size_kb + entry_size_kb))
                    fi
                done

                if [[ $removed_count -gt 0 ]]; then
                    stale_size_human=$(bytes_to_human "$((removed_size_kb * 1024))")
                    local line_color
                    line_color=$(cleanup_result_color_kb "$removed_size_kb")
                    echo -e "  ${line_color}${ICON_SUCCESS}${NC} ${display_name} · removed ${removed_count} old versions, ${line_color}${stale_size_human}${NC}"
                    files_cleaned=$((${files_cleaned:-0} + removed_count))
                    total_size_cleaned=$((${total_size_cleaned:-0} + removed_size_kb))
                    total_items=$((${total_items:-0} + 1))
                    note_activity
                fi
                if [[ -n "$stop_reason" ]]; then
                    if [[ "$stop_reason" == "process state unknown" ]]; then
                        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${stop_reason})"
                        note_activity
                    else
                        mole_defer_cleanup_family "Xcode"
                    fi
                    return 0
                fi
            fi
        fi
    fi

    # Clean caches/logs inside kept versions. In dry-run, stale versions still
    # exist on disk but their whole directories are already in the preview
    # ledger, so exclude their children to avoid double-counting.
    local -a inner_cache_targets=()
    local -a log_targets=()
    local stale_dir skip_inner
    for candidate in "$ds_dir"/*/Symbols/System/Library/Caches/*; do
        skip_inner=false
        if [[ "${DRY_RUN:-false}" == "true" && ${#preview_stale_dirs[@]} -gt 0 ]]; then
            for stale_dir in "${preview_stale_dirs[@]}"; do
                case "$candidate" in
                    "$stale_dir"/*)
                        skip_inner=true
                        break
                        ;;
                esac
            done
        fi
        [[ "$skip_inner" == "true" ]] && continue
        mole_cleanup_targets_exist "$candidate" && inner_cache_targets+=("$candidate")
    done
    for candidate in "$ds_dir"/*.log; do
        mole_cleanup_targets_exist "$candidate" && log_targets+=("$candidate")
    done
    if [[ ${#inner_cache_targets[@]} -eq 0 && ${#log_targets[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        process_state=0
        _xcode_xctest_devices_process_running || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            local stop_reason="Xcode or build tools started"
            [[ $process_state -eq 2 ]] && stop_reason="process state unknown"
            if [[ "$stop_reason" == "process state unknown" ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${stop_reason})"
                note_activity
            else
                mole_defer_cleanup_family "Xcode"
            fi
            return 0
        fi
    fi
    if [[ ${#inner_cache_targets[@]} -gt 0 ]]; then
        _xcode_safe_clean_guarded \
            _xcode_delete_guard_allows \
            "$display_name symbol cache" \
            "${inner_cache_targets[@]}" \
            "$display_name symbol cache" || return 0
    fi
    if [[ ${#log_targets[@]} -gt 0 ]]; then
        _xcode_safe_clean_guarded \
            _xcode_delete_guard_allows \
            "$display_name logs" \
            "${log_targets[@]}" \
            "$display_name logs" || return 0
    fi
}

_sim_runtime_mount_points() {
    if [[ -n "${MOLE_XCODE_SIM_RUNTIME_MOUNT_POINTS:-}" ]]; then
        printf '%s\n' "$MOLE_XCODE_SIM_RUNTIME_MOUNT_POINTS"
        return 0
    fi
    mount 2> /dev/null | command awk '{print $3}' || true
}

_sim_runtime_is_path_in_use() {
    local target_path="$1"
    shift || true
    local mount_path
    for mount_path in "$@"; do
        [[ -z "$mount_path" ]] && continue
        if [[ "$mount_path" == "$target_path" || "$mount_path" == "$target_path"/* ]]; then
            return 0
        fi
    done
    return 1
}

_sim_runtime_size_kb() {
    local target_path="$1"
    local size_kb=0
    if has_sudo_session; then
        size_kb=$(run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" sudo -n du -skP "$target_path" 2> /dev/null | command awk 'NR==1 {print $1; exit}' || echo "0")
    else
        size_kb=$(run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" du -skP "$target_path" 2> /dev/null | command awk 'NR==1 {print $1; exit}' || echo "0")
    fi

    [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
    echo "$size_kb"
}

clean_xcode_simulator_runtime_volumes() {
    local volumes_root="${MOLE_XCODE_SIM_RUNTIME_VOLUMES_ROOT:-/Library/Developer/CoreSimulator/Volumes}"
    local cryptex_root="${MOLE_XCODE_SIM_RUNTIME_CRYPTEX_ROOT:-/Library/Developer/CoreSimulator/Cryptex}"

    local -a candidates=()
    local candidate
    for candidate in "$volumes_root" "$cryptex_root"; do
        [[ -d "$candidate" ]] || continue
        while IFS= read -r -d '' entry; do
            candidates+=("$entry")
        done < <(command find "$candidate" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 0
    fi

    local -a mount_points=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && mount_points+=("$line")
    done < <(_sim_runtime_mount_points)

    # A real macOS system always mounts at least "/", so an empty list means
    # `mount` failed. Without this guard every candidate falls to the UNUSED
    # branch below and gets sudo-deleted, possibly while still mounted. Treat
    # "cannot enumerate mounts" as "cannot prove unused" and skip cleanup.
    if [[ ${#mount_points[@]} -eq 0 ]]; then
        return 0
    fi

    local -a entry_statuses=()
    local -a sorted_candidates=()
    local sorted
    while IFS= read -r sorted; do
        [[ -n "$sorted" ]] && sorted_candidates+=("$sorted")
    done < <(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort)

    # Only show scanning message in debug mode; spinner provides visual feedback otherwise
    if [[ "${MO_DEBUG:-0}" == "1" ]]; then
        echo -e "  ${GRAY}${ICON_LIST}${NC} Xcode runtime volumes · scanning ${#sorted_candidates[@]} entries"
    fi
    local runtime_scan_spinner=false
    if [[ -t 1 ]]; then
        start_section_spinner "Scanning Xcode runtime volumes..."
        runtime_scan_spinner=true
    fi

    local in_use_count=0
    for candidate in "${sorted_candidates[@]}"; do
        local status="UNUSED"
        if [[ ${#mount_points[@]} -gt 0 ]] && _sim_runtime_is_path_in_use "$candidate" "${mount_points[@]}"; then
            status="IN_USE"
            in_use_count=$((in_use_count + 1))
        fi
        entry_statuses+=("$status")
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        local -a size_values=()
        local unused_kb=0
        local cleanable_unused_count=0
        local preview_in_use_count=0
        local dry_stop_reason=""
        local i=0
        for candidate in "${sorted_candidates[@]}"; do
            local status="${entry_statuses[$i]:-UNUSED}"
            if [[ "$status" == "IN_USE" ]]; then
                # Mounted runtimes cannot be removed by this run. Walking a
                # multi-GB mounted image only to report a non-reclaimable size
                # dominated dry-run latency, so keep the state and skip du.
                size_values+=("-1")
                preview_in_use_count=$((preview_in_use_count + 1))
            else
                local size_kb
                size_kb=$(_sim_runtime_size_kb "$candidate")
                local -a current_mount_points=()
                while IFS= read -r line; do
                    [[ -n "$line" ]] && current_mount_points+=("$line")
                done < <(_sim_runtime_mount_points)
                if [[ ${#current_mount_points[@]} -eq 0 ]]; then
                    dry_stop_reason="mount state unknown"
                    break
                fi
                if _sim_runtime_is_path_in_use "$candidate" "${current_mount_points[@]}"; then
                    dry_stop_reason="runtime became mounted"
                    break
                fi
                if ! should_protect_path "$candidate" && ! is_path_whitelisted "$candidate"; then
                    if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                        record_dry_run_cleanup_target "$candidate" "$size_kb" 1 true || {
                            size_values+=("$size_kb")
                            i=$((i + 1))
                            continue
                        }
                    fi
                    unused_kb=$((unused_kb + size_kb))
                    cleanable_unused_count=$((cleanable_unused_count + 1))
                fi
                size_values+=("$size_kb")
            fi
            i=$((i + 1))
        done
        if [[ "$runtime_scan_spinner" == "true" ]]; then
            stop_section_spinner
            runtime_scan_spinner=false
        fi

        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Xcode runtime volumes · ${cleanable_unused_count} unused, ${preview_in_use_count} in use"
        local dryrun_unused_human
        dryrun_unused_human=$(bytes_to_human "$((unused_kb * 1024))")
        local in_use_size_note=""
        if [[ $preview_in_use_count -gt 0 ]]; then
            in_use_size_note=" (in-use not scanned)"
        fi
        echo -e "  ${GRAY}${ICON_LIST}${NC} Runtime volume size: unused ${dryrun_unused_human}${in_use_size_note}"

        local dryrun_max_items="${MOLE_SIM_RUNTIME_DRYRUN_MAX_ITEMS:-20}"
        [[ "$dryrun_max_items" =~ ^[0-9]+$ ]] || dryrun_max_items=20
        if [[ "$dryrun_max_items" -le 0 ]]; then
            dryrun_max_items=20
        fi

        local shown=0
        local line_size_kb line_status line_path
        while IFS=$'\t' read -r line_size_kb line_status line_path; do
            [[ -z "${line_path:-}" ]] && continue
            local line_human
            if [[ "$line_size_kb" == "-1" ]]; then
                line_human="not scanned"
            else
                line_human=$(bytes_to_human "$((line_size_kb * 1024))")
            fi
            echo -e "    ${GRAY}${line_status}${NC} ${line_human} · ${line_path}"
            shown=$((shown + 1))
            if [[ "$shown" -ge "$dryrun_max_items" ]]; then
                break
            fi
        done < <(
            local j=0
            while [[ $j -lt ${#sorted_candidates[@]} ]]; do
                printf '%s\t%s\t%s\n' "${size_values[$j]:-0}" "${entry_statuses[$j]:-UNUSED}" "${sorted_candidates[$j]}"
                j=$((j + 1))
            done | LC_ALL=C sort -nr -k1,1
        )

        local total_entries="${#size_values[@]}"
        if [[ "$total_entries" -gt "$shown" ]]; then
            local remaining=$((total_entries - shown))
            echo -e "    ${GRAY}${ICON_LIST}${NC} ... and ${remaining} more runtime volume entries"
        fi
        note_activity
        if [[ -n "$dry_stop_reason" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode runtime volumes · stopped (${dry_stop_reason})"
            note_activity
        fi
        return 0
    fi

    # Auto-clean all UNUSED runtime volumes (no user selection)
    local -a selected_paths=()
    local skipped_protected=0
    local i=0
    for ((i = 0; i < ${#sorted_candidates[@]}; i++)); do
        local status="${entry_statuses[$i]:-UNUSED}"
        [[ "$status" == "IN_USE" ]] && continue

        local candidate_path="${sorted_candidates[$i]}"
        if should_protect_path "$candidate_path" || is_path_whitelisted "$candidate_path"; then
            skipped_protected=$((skipped_protected + 1))
            continue
        fi
        selected_paths+=("$candidate_path")
    done

    if [[ "$runtime_scan_spinner" == "true" ]]; then
        stop_section_spinner
        runtime_scan_spinner=false
    fi

    if [[ ${#selected_paths[@]} -eq 0 ]]; then
        debug_log "Xcode runtime volumes have no unused cleanable entries"
        return 0
    fi

    if ! has_sudo_session; then
        if ! ensure_sudo_session "Cleaning Xcode runtime volumes requires admin access"; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Xcode runtime volumes · skipped (sudo denied)"
            note_activity
            return 0
        fi
    fi

    # Perform cleanup and report final result in one line
    local removed_count=0
    local removed_size_kb=0
    local failed_count=0
    local stop_reason=""
    local selected_path
    for selected_path in "${selected_paths[@]}"; do
        local selected_size_kb=0
        selected_size_kb=$(_sim_runtime_size_kb "$selected_path")

        # Mount state can change while sizing or waiting for sudo. Refresh it
        # for each candidate and stop when the path is mounted or the probe is
        # unavailable; an old UNUSED snapshot never authorizes deletion.
        local -a current_mount_points=()
        while IFS= read -r line; do
            [[ -n "$line" ]] && current_mount_points+=("$line")
        done < <(_sim_runtime_mount_points)
        if [[ ${#current_mount_points[@]} -eq 0 ]]; then
            stop_reason="mount state unknown"
            break
        fi
        if _sim_runtime_is_path_in_use "$selected_path" "${current_mount_points[@]}"; then
            stop_reason="runtime became mounted"
            break
        fi

        if safe_sudo_remove "$selected_path" "$selected_size_kb"; then
            removed_count=$((removed_count + 1))
            removed_size_kb=$((removed_size_kb + selected_size_kb))
        else
            failed_count=$((failed_count + 1))
        fi
    done

    # Unified output: report result, not intermediate steps
    if [[ $removed_count -gt 0 ]]; then
        local removed_human
        removed_human=$(bytes_to_human "$((removed_size_kb * 1024))")
        local line_color
        line_color=$(cleanup_result_color_kb "$removed_size_kb")
        if [[ $skipped_protected -gt 0 ]]; then
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode runtime volumes · removed ${removed_count} (${line_color}${removed_human}${NC}), skipped ${skipped_protected} protected"
        else
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode runtime volumes · removed ${removed_count} (${line_color}${removed_human}${NC})"
        fi
        if [[ $failed_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode runtime volumes · could not remove ${failed_count} entries"
        fi
        note_activity
    else
        if [[ $failed_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode runtime volumes · could not remove ${failed_count} entries"
            if [[ $skipped_protected -gt 0 ]]; then
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Xcode runtime volumes · skipped ${skipped_protected} protected"
            fi
        elif [[ $skipped_protected -gt 0 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Xcode runtime volumes · skipped ${skipped_protected} protected, none removed"
        fi
        if [[ $failed_count -gt 0 || $skipped_protected -gt 0 ]]; then
            note_activity
        fi
    fi
    if [[ -n "$stop_reason" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode runtime volumes · stopped (${stop_reason})"
        note_activity
    fi
}

_MOLE_SIMCTL_DEVELOPER_DIR=""
_MOLE_SIMCTL_RESOLUTION_STATUS="unavailable"
_MOLE_SIMCTL_XCODE_APP_ROOTS=(
    "/Applications"
    "$HOME/Applications"
)

_simctl_developer_dir_is_usable() {
    local developer_dir="$1"
    [[ -d "$developer_dir" ]] || return 1

    run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        env "DEVELOPER_DIR=$developer_dir" xcrun --find simctl > /dev/null 2>&1
}

# Resolve simctl without changing the machine-wide xcode-select setting.
# An explicit DEVELOPER_DIR is authoritative: if it is invalid, do not
# silently switch the caller to a different Xcode installation.
_resolve_simctl_developer_dir() {
    _MOLE_SIMCTL_DEVELOPER_DIR=""
    _MOLE_SIMCTL_RESOLUTION_STATUS="unavailable"

    if [[ -n "${DEVELOPER_DIR:-}" ]]; then
        if _simctl_developer_dir_is_usable "$DEVELOPER_DIR"; then
            _MOLE_SIMCTL_DEVELOPER_DIR="$DEVELOPER_DIR"
            _MOLE_SIMCTL_RESOLUTION_STATUS="ready"
            return 0
        fi

        _MOLE_SIMCTL_RESOLUTION_STATUS="explicit-invalid"
        debug_log "Explicit DEVELOPER_DIR does not provide simctl: $DEVELOPER_DIR"
        return 1
    fi

    local selected_developer_dir=""
    local selected_is_clt=false
    if command -v xcode-select > /dev/null 2>&1; then
        selected_developer_dir=$(xcode-select -p 2> /dev/null || true)
    fi
    case "$selected_developer_dir" in
        /Library/Developer/CommandLineTools | /Library/Developer/CommandLineTools/)
            selected_is_clt=true
            ;;
        "")
            return 1
            ;;
        *)
            if _simctl_developer_dir_is_usable "$selected_developer_dir"; then
                _MOLE_SIMCTL_DEVELOPER_DIR="$selected_developer_dir"
                _MOLE_SIMCTL_RESOLUTION_STATUS="ready"
                return 0
            fi
            debug_log "Selected Xcode does not provide simctl: $selected_developer_dir"
            return 1
            ;;
    esac

    local -a candidates=()
    local app_root candidate_app candidate_developer_dir
    local xcode_app_found=false
    local nullglob_was_set=0
    shopt -q nullglob && nullglob_was_set=1
    shopt -s nullglob
    for app_root in "${_MOLE_SIMCTL_XCODE_APP_ROOTS[@]}"; do
        [[ -d "$app_root" ]] || continue
        for candidate_app in "$app_root"/Xcode*.app; do
            [[ -d "$candidate_app" ]] || continue
            xcode_app_found=true
            candidate_developer_dir="$candidate_app/Contents/Developer"
            if _simctl_developer_dir_is_usable "$candidate_developer_dir"; then
                candidates+=("$candidate_developer_dir")
            fi
        done
    done
    if [[ $nullglob_was_set -eq 0 ]]; then
        shopt -u nullglob
    fi

    if [[ "$selected_is_clt" == true && "$xcode_app_found" == false ]]; then
        _MOLE_SIMCTL_RESOLUTION_STATUS="clt-only"
        debug_log "Standalone Command Line Tools selected; no Xcode app is installed"
        return 1
    fi

    if [[ ${#candidates[@]} -eq 1 ]]; then
        _MOLE_SIMCTL_DEVELOPER_DIR="${candidates[0]}"
        _MOLE_SIMCTL_RESOLUTION_STATUS="ready"
        debug_log "Using detected Xcode for simctl: ${candidates[0]%/Contents/Developer}"
        return 0
    fi

    if [[ ${#candidates[@]} -gt 1 ]]; then
        _MOLE_SIMCTL_RESOLUTION_STATUS="ambiguous"
        for candidate_developer_dir in "${candidates[@]}"; do
            debug_log "simctl Xcode candidate: ${candidate_developer_dir%/Contents/Developer}"
        done
    fi

    return 1
}

_run_simctl() {
    local timeout_seconds="$1"
    shift

    [[ "$_MOLE_SIMCTL_RESOLUTION_STATUS" == "ready" ]] || return 127
    run_with_timeout "$timeout_seconds" \
        env "DEVELOPER_DIR=$_MOLE_SIMCTL_DEVELOPER_DIR" xcrun simctl "$@"
}

_simctl_debug_excerpt() {
    local value="$1"
    value=$(printf '%s' "$value" | LC_ALL=C tr '\r\n\t' '   ' | LC_ALL=C tr -cd '[:print:] ') || value=""

    if [[ -n "${HOME:-}" ]]; then
        local prefix suffix
        while [[ "$value" == *"$HOME"* ]]; do
            prefix=${value%%"$HOME"*}
            suffix=${value#*"$HOME"}
            value="${prefix}~${suffix}"
        done
    fi

    if [[ ${#value} -gt 240 ]]; then
        value="${value:0:240}..."
    fi
    printf '%s' "$value"
}

_debug_simctl_probe_stderr() {
    local attempt="$1"
    local raw_stderr="$2"
    local excerpt
    excerpt=$(_simctl_debug_excerpt "$raw_stderr")
    [[ -n "$excerpt" ]] || return 0
    debug_log "simctl probe $attempt stderr: $excerpt"
}

# Installed simulator runtimes that no device uses. Distinct from
# clean_xcode_simulator_runtime_volumes (stale mount points) and from
# unavailable-simulator cleanup (devices orphaned by a removed runtime):
# this is the inverse, a runtime left behind after its last device went
# away. Nothing in macOS or Xcode reports it, so an 8GB download can sit
# unreferenced indefinitely.
#
# Review-only by design. A runtime is a toolchain payload that only Apple
# can serve again, so it stays off the blanket delete path the same way
# other downloaded toolchain roots do; the value here is naming the exact
# orphan and the owner command, which is information the user cannot get
# from simctl directly.
#
# The join keys on runtimeIdentifier from `-j` output, never on the printed
# runtime name. The two human-readable listings disagree by design: `runtime
# list` heads each image with the image version ("iOS 26.4.1") while `list
# devices` groups under the runtime's short name ("iOS 26.4"), so a name join
# calls every point release an orphan and tells the user to delete a runtime
# its simulators are still bound to.

# One tab-separated row per orphaned runtime image: id, platform, version,
# build, sizeBytes. Reads both `-j` payloads in a single awk pass, devices
# first, then joins on runtimeIdentifier.
#
# A row survives only on complete evidence. The image must be Ready and
# deletable, so nothing mid-download or owned by Xcode itself is offered. Its
# runtime identifier must be served by exactly one installed image, because
# the device list keys on the identifier and cannot say which of two images
# the devices belong to. And udid entries are counted rather than trusting how
# an empty array happens to be rendered.
_simctl_orphan_runtime_rows() {
    printf '%s\n=== MOLE RUNTIME PAYLOAD ===\n%s\n' "$1" "$2" | awk '
        function val(line,   v) {
            v = line
            sub(/^ *"[^"]+" *: */, "", v)
            sub(/,$/, "", v)
            gsub(/^"|"$/, "", v)
            return v
        }
        function key(line,   k) {
            k = line
            sub(/^ *"/, "", k)
            sub(/" *:.*$/, "", k)
            return k
        }
        function flush_device_group() {
            if (group != "" && members > 0) used[group] = 1
            group = ""
            members = 0
        }
        function flush_runtime_image() {
            if (id == "" || rid == "") return
            n++
            r_id[n] = id
            r_rid[n] = rid
            r_ver[n] = ver
            r_build[n] = build
            r_size[n] = size
            r_del[n] = del
            r_state[n] = state
            served[rid]++
            id = ""; rid = ""; ver = ""; build = ""; size = ""; del = ""; state = ""
        }
        /^=== MOLE RUNTIME PAYLOAD ===$/ { flush_device_group(); phase = 2; next }
        phase != 2 {
            if (!in_devices) { if ($0 ~ /^  "devices" *:/) in_devices = 1; next }
            if ($0 ~ /^    "/) { flush_device_group(); group = key($0); next }
            if ($0 ~ /^  \}/) { flush_device_group(); in_devices = 0; next }
            if ($0 ~ /"udid"/) members++
            next
        }
        /^  "[^"]+" *: *\{/ { flush_runtime_image(); id = key($0); next }
        /^    "runtimeIdentifier" *:/ { rid = val($0); next }
        /^    "version" *:/ { ver = val($0); next }
        /^    "build" *:/ { build = val($0); next }
        /^    "sizeBytes" *:/ { size = val($0); next }
        /^    "deletable" *:/ { del = val($0); next }
        /^    "state" *:/ { state = val($0); next }
        END {
            flush_runtime_image()
            for (i = 1; i <= n; i++) {
                if (r_state[i] != "Ready" || r_del[i] != "true") continue
                if (served[r_rid[i]] != 1) continue
                if (r_rid[i] in used) continue
                platform = r_rid[i]
                sub(/^.*\./, "", platform)
                sub(/-.*$/, "", platform)
                if (platform == "") platform = "Simulator"
                printf "%s\t%s\t%s\t%s\t%s\n", r_id[i], platform, r_ver[i], r_build[i], r_size[i]
            }
        }'
}

check_orphaned_simulator_runtimes() {
    command -v xcrun > /dev/null 2>&1 || return 0
    [[ "${_MOLE_SIMCTL_RESOLUTION_STATUS:-}" == "ready" ]] || return 0

    local runtime_json="" device_json="" probe_status=0
    runtime_json=$(_run_simctl "$MOLE_TIMEOUT_PKG_LIST_SEC" runtime list -j 2> /dev/null) || probe_status=$?
    if [[ $probe_status -ne 0 ]]; then
        [[ $probe_status -eq 124 || $probe_status -ge 128 ]] && return "$probe_status"
        debug_log "Orphaned runtime probe failed (exit=$probe_status)"
        return 0
    fi

    probe_status=0
    device_json=$(_run_simctl "$MOLE_TIMEOUT_PKG_LIST_SEC" list devices -j 2> /dev/null) || probe_status=$?
    if [[ $probe_status -ne 0 ]]; then
        [[ $probe_status -eq 124 || $probe_status -ge 128 ]] && return "$probe_status"
        debug_log "Orphaned runtime device probe failed (exit=$probe_status)"
        return 0
    fi
    # Without a recognizable device payload there is no evidence of absence,
    # only absence of evidence.
    [[ "$device_json" == *'"devices"'* ]] || return 0

    local id platform version build size_bytes size_note build_note
    while IFS=$'\t' read -r id platform version build size_bytes; do
        [[ -n "$id" && -n "$platform" ]] || continue
        size_note=""
        [[ "$size_bytes" =~ ^[0-9]+$ ]] && size_note=", $(bytes_to_human "$size_bytes")"
        build_note="${build:+ ($build)}"
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Orphaned simulator runtime · ${platform} ${version}${build_note}${size_note} · no devices · remove with ${GRAY}xcrun simctl runtime delete ${id}${NC}"
        note_activity
    done < <(_simctl_orphan_runtime_rows "$device_json" "$runtime_json")
    return 0
}

clean_dev_mobile() {
    check_android_ndk
    clean_xcode_documentation_cache || return $?
    clean_xcode_system_coresimulator_caches || return $?
    clean_xcode_simulator_runtime_volumes || return $?
    clean_xcode_xctest_devices || return $?

    if command -v xcrun > /dev/null 2>&1; then
        _resolve_simctl_developer_dir || true
        if [[ "$_MOLE_SIMCTL_RESOLUTION_STATUS" == "ambiguous" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode unavailable simulators · multiple Xcode apps found; set DEVELOPER_DIR"
            note_activity
        elif [[ "$_MOLE_SIMCTL_RESOLUTION_STATUS" == "explicit-invalid" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode unavailable simulators · DEVELOPER_DIR has no simctl"
            note_activity
        elif [[ "$_MOLE_SIMCTL_RESOLUTION_STATUS" == "clt-only" ]]; then
            debug_log "Skipping unavailable simulator cleanup without a full Xcode installation"
        elif [[ "$_MOLE_SIMCTL_RESOLUTION_STATUS" == "ready" ]]; then
            debug_log "Checking for unavailable Xcode simulators"
            debug_log "Resolved simctl DEVELOPER_DIR: $_MOLE_SIMCTL_DEVELOPER_DIR"
            local unavailable_before=0
            local unavailable_after=0
            local removed_unavailable=0
            local unavailable_size_kb=0
            local unavailable_size_human="0B"
            local -a unavailable_udids=()
            local unavailable_udid=""
            local unavailable_devices_output=""

            # The unavailable-device listing is both the capability probe and
            # the data this cleanup needs. A separate `list devices` launch
            # made every successful clean wait for CoreSimulator twice.
            # CoreSimulatorService can still need a warm-up retry (#890).
            local simctl_available=true
            local simctl_probe_ok=false
            local simctl_probe_first_status=0
            local simctl_probe_retry_status=0
            local simctl_probe_first_stderr=""
            local simctl_probe_retry_stderr=""
            local simctl_probe_stderr_file=""
            local simctl_probe_stderr_target="/dev/null"
            if ensure_mole_temp_root && [[ -n "${MOLE_RESOLVED_TMPDIR:-}" ]]; then
                simctl_probe_stderr_file=$(mktemp "$MOLE_RESOLVED_TMPDIR/mole-simctl-probe.XXXXXX" 2> /dev/null || true)
            fi
            if [[ -n "$simctl_probe_stderr_file" ]]; then
                simctl_probe_stderr_target="$simctl_probe_stderr_file"
            else
                debug_log "Unable to create simctl probe stderr capture file"
            fi

            if unavailable_devices_output=$(_run_simctl \
                "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" list devices unavailable \
                2> "$simctl_probe_stderr_target"); then
                simctl_probe_ok=true
            else
                simctl_probe_first_status=$?
                unavailable_devices_output=""
                if [[ -n "$simctl_probe_stderr_file" ]]; then
                    simctl_probe_first_stderr=$(< "$simctl_probe_stderr_file")
                    : > "$simctl_probe_stderr_file"
                fi
                if unavailable_devices_output=$(_run_simctl \
                    "$MOLE_TIMEOUT_PKG_LIST_SEC" list devices unavailable \
                    2> "$simctl_probe_stderr_target"); then
                    simctl_probe_ok=true
                    simctl_probe_retry_status=0
                    debug_log "simctl probe succeeded on retry (CoreSimulatorService warmup)"
                else
                    simctl_probe_retry_status=$?
                    unavailable_devices_output=""
                fi
                if [[ -n "$simctl_probe_stderr_file" ]]; then
                    simctl_probe_retry_stderr=$(< "$simctl_probe_stderr_file")
                fi
                debug_log "simctl probe statuses: first=$simctl_probe_first_status retry=$simctl_probe_retry_status"
                _debug_simctl_probe_stderr "first" "$simctl_probe_first_stderr"
                _debug_simctl_probe_stderr "retry" "$simctl_probe_retry_stderr"
            fi
            if [[ -n "$simctl_probe_stderr_file" ]]; then
                rm -f -- "$simctl_probe_stderr_file" 2> /dev/null || true # SAFE: exact temporary file created by mktemp above
            fi
            if [[ "$simctl_probe_ok" != "true" ]]; then
                if [[ $simctl_probe_first_status -eq 124 && $simctl_probe_retry_status -eq 124 ]]; then
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode unavailable simulators · simctl probe timed out"
                else
                    local simctl_probe_exit_code=$simctl_probe_retry_status
                    if [[ $simctl_probe_exit_code -eq 124 ]]; then
                        simctl_probe_exit_code=$simctl_probe_first_status
                    fi
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode unavailable simulators · simctl probe failed (exit=${simctl_probe_exit_code})"
                fi
                note_activity
                simctl_available=false
            fi

            if [[ "$simctl_available" == "true" ]]; then
                unavailable_before=$(printf '%s\n' "$unavailable_devices_output" | command awk '/\(unavailable/ { count++ } END { print count+0 }')
                [[ "$unavailable_before" =~ ^[0-9]+$ ]] || unavailable_before=0
                while IFS= read -r unavailable_udid; do
                    [[ -n "$unavailable_udid" ]] && unavailable_udids+=("$unavailable_udid")
                done < <(
                    printf '%s\n' "$unavailable_devices_output" |
                        command sed -nE 's/.*\(([0-9A-Fa-f-]{36})\).*\(unavailable.*/\1/p' || true
                )
                if [[ ${#unavailable_udids[@]} -gt 0 ]]; then
                    local udid
                    for udid in "${unavailable_udids[@]}"; do
                        local simulator_device_path="$HOME/Library/Developer/CoreSimulator/Devices/$udid"
                        if [[ -d "$simulator_device_path" ]]; then
                            local simulator_size_kb=""
                            local size_rc=0
                            simulator_size_kb=$(get_path_size_kb "$simulator_device_path") || size_rc=$?
                            [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
                            [[ $size_rc -eq 0 ]] || return "$size_rc"
                            [[ "$simulator_size_kb" =~ ^[0-9]+$ ]] || simulator_size_kb=0
                            unavailable_size_kb=$((unavailable_size_kb + simulator_size_kb))
                        fi
                    done
                fi
                unavailable_size_human=$(bytes_to_human "$((unavailable_size_kb * 1024))")

                if [[ "$DRY_RUN" == "true" ]]; then
                    if ((unavailable_before > 0)); then
                        for unavailable_udid in "${unavailable_udids[@]}"; do
                            local unavailable_path="$HOME/Library/Developer/CoreSimulator/Devices/$unavailable_udid"
                            [[ -d "$unavailable_path" ]] || continue
                            local unavailable_path_size_kb
                            size_rc=0
                            unavailable_path_size_kb=$(get_path_size_kb "$unavailable_path" 2> /dev/null) || size_rc=$?
                            [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
                            [[ $size_rc -eq 0 ]] || return "$size_rc"
                            [[ "$unavailable_path_size_kb" =~ ^[0-9]+$ ]] || unavailable_path_size_kb=0
                            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                                record_dry_run_cleanup_target "$unavailable_path" "$unavailable_path_size_kb" 1 true || true
                            fi
                        done
                        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Xcode unavailable simulators · would clean ${unavailable_before}, ${unavailable_size_human}"
                        note_activity
                    else
                        debug_log "Xcode unavailable simulators already clean"
                    fi
                else
                    # Skip if no unavailable simulators
                    if ((unavailable_before == 0)); then
                        debug_log "Xcode unavailable simulators already clean"
                    else
                        start_section_spinner "Checking unavailable simulators..."

                        # Capture error output for diagnostics
                        local delete_output
                        local delete_exit_code=0
                        delete_output=$(_run_simctl "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" delete unavailable 2>&1) || delete_exit_code=$?

                        if [[ $delete_exit_code -eq 0 ]]; then
                            stop_section_spinner
                            local recount_exit_code=0
                            unavailable_devices_output=$(_run_simctl "$MOLE_TIMEOUT_PKG_LIST_SEC" list devices unavailable 2> /dev/null) || recount_exit_code=$?
                            if [[ $recount_exit_code -ne 0 ]]; then
                                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Xcode unavailable simulators · cleanup completed, unable to verify remaining devices"
                                debug_log "simctl recount returned $recount_exit_code"
                            else
                                unavailable_after=$(printf '%s\n' "$unavailable_devices_output" | command awk '/\(unavailable/ { count++ } END { print count+0 }')
                                [[ "$unavailable_after" =~ ^[0-9]+$ ]] || unavailable_after=0

                                removed_unavailable=$((unavailable_before - unavailable_after))
                                if ((removed_unavailable < 0)); then
                                    removed_unavailable=0
                                fi

                                local line_color
                                line_color=$(cleanup_result_color_kb "$unavailable_size_kb")
                                if ((removed_unavailable > 0)); then
                                    echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode unavailable simulators · removed ${removed_unavailable}, ${line_color}${unavailable_size_human}${NC}"
                                else
                                    echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode unavailable simulators · cleanup completed, ${line_color}${unavailable_size_human}${NC}"
                                fi
                            fi
                        else
                            stop_section_spinner

                            # Analyze error and provide helpful message
                            local error_hint=""
                            if echo "$delete_output" | grep -qi "permission denied"; then
                                error_hint=" (permission denied)"
                            elif echo "$delete_output" | grep -qi "in use\|busy"; then
                                error_hint=" (device in use)"
                            elif echo "$delete_output" | grep -qi "unable to boot\|failed to boot"; then
                                error_hint=" (boot failure)"
                            elif echo "$delete_output" | grep -qi "service"; then
                                error_hint=" (CoreSimulator service issue)"
                            fi

                            # Native simctl owns simulator state. A nonzero result can
                            # mean the device became active after the list, so never
                            # bypass it with direct directory removal.
                            if [[ $delete_exit_code -eq 124 ]]; then
                                echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode unavailable simulators · cleanup timed out"
                                debug_log "simctl delete unavailable timed out"
                            else
                                echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode unavailable simulators cleanup failed${error_hint}"
                                debug_log "simctl delete error: $delete_output"
                            fi
                        fi
                        note_activity
                    fi
                fi # Close if ((unavailable_before == 0))
            fi     # End of simctl_available check
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode unavailable simulators · simctl could not be resolved"
            note_activity
        fi
        check_orphaned_simulator_runtimes || return $?
    fi
    # Old iOS/watchOS/tvOS DeviceSupport versions (debug symbols for connected devices).
    # Each iOS version creates a 1-3 GB folder of debug symbols. Only the versions
    # matching currently used devices are needed; older ones regenerate on device connect.
    clean_xcode_device_support ~/Library/Developer/Xcode/iOS\ DeviceSupport "iOS DeviceSupport" || return $?
    clean_xcode_device_support ~/Library/Developer/Xcode/watchOS\ DeviceSupport "watchOS DeviceSupport" || return $?
    clean_xcode_device_support ~/Library/Developer/Xcode/tvOS\ DeviceSupport "tvOS DeviceSupport" || return $?
    # Simulator runtime caches.
    _xcode_safe_clean_guarded \
        _coresimulator_delete_guard_allows \
        "Simulator runtime cache" \
        ~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/Contents/Resources/RuntimeRoot/System/Library/Caches/* \
        "Simulator runtime cache" || return 0
    safe_clean ~/Library/Caches/Google/AndroidStudio*/* "Android Studio cache"
    # safe_clean ~/Library/Caches/CocoaPods/* "CocoaPods cache"
    # safe_clean ~/.cache/flutter/* "Flutter cache"
    safe_clean ~/.android/build-cache/* "Android build cache"
    safe_clean ~/.android/cache/* "Android SDK cache"
    _xcode_safe_clean_guarded \
        _xcode_delete_guard_allows \
        "Xcode Interface Builder cache" \
        ~/Library/Developer/Xcode/UserData/IB\ Support/* \
        "Xcode Interface Builder cache" || return 0
    safe_clean ~/.cache/swift-package-manager/* "Swift package manager cache"
    safe_clean ~/Library/Caches/org.swift.swiftpm/* "Swift package manager library cache"
    # Expo/React Native caches (preserve state.json which contains auth tokens).
    safe_clean ~/.expo/expo-go/* "Expo Go cache"
    safe_clean ~/.expo/android-apk-cache/* "Expo Android APK cache"
    safe_clean ~/.expo/ios-simulator-app-cache/* "Expo iOS simulator app cache"
    safe_clean ~/.expo/native-modules-cache/* "Expo native modules cache"
    safe_clean ~/.expo/schema-cache/* "Expo schema cache"
    safe_clean ~/.expo/template-cache/* "Expo template cache"
    safe_clean ~/.expo/versions-cache/* "Expo versions cache"
}
# JVM ecosystem caches.
# Gradle: Respects whitelist, cleaned when not protected via: mo clean --whitelist
clean_dev_jvm() {
    # Excluded on purpose, all for the same reason: ~/.m2/repository and
    # ~/.ivy2/cache are the stores Maven, sbt and Ivy resolve dependencies
    # from, and ~/.sbt/boot with ~/.sbt/launchers hold the Scala compiler and
    # sbt launcher jars themselves. clean_large_files reports them for review.
    # Maven used to be cleaned here and relied on DEFAULT_WHITELIST_PATTERNS to
    # stay safe, which stops applying as soon as a user saves any whitelist
    # entry of their own, so the delete path is gone rather than guarded.
    if mole_cleanup_targets_exist \
        "$HOME/.gradle/caches/build-cache-"*/* \
        "$HOME/.gradle/notifications"/* \
        "$HOME/.gradle/daemon"/* \
        "$HOME/.gradle/workers"/*; then
        local gradle_state=0
        gradle_daemon_running || gradle_state=$?
        if [[ $gradle_state -eq 0 ]]; then
            mole_defer_cleanup_family "Gradle"
        elif [[ $gradle_state -eq 1 ]]; then
            # Each group rechecks the probe at its deletion boundary; any
            # refusal stops the remaining Gradle cleanup.
            _dev_safe_clean_process_guarded \
                gradle_daemon_running \
                "Gradle" \
                "Gradle build cache" \
                "$HOME/.gradle/caches/build-cache-"*/* \
                "Gradle build cache" || return 0
            _dev_safe_clean_process_guarded \
                gradle_daemon_running \
                "Gradle" \
                "Gradle notifications cache" \
                "$HOME/.gradle/notifications"/* \
                "Gradle notifications cache" || return 0
            _dev_safe_clean_process_guarded \
                gradle_daemon_running \
                "Gradle" \
                "Gradle daemon/workers" \
                "$HOME/.gradle/daemon"/* \
                "$HOME/.gradle/workers"/* \
                "Gradle daemon/workers" || return 0
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Gradle targets · skipped (process state unknown)"
            note_activity
        fi
    fi
}
# JetBrains Toolbox old IDE versions (keep current + recent backup).
clean_dev_jetbrains_toolbox() {
    local toolbox_root="$HOME/Library/Application Support/JetBrains/Toolbox/apps"
    [[ -d "$toolbox_root" ]] || return 0

    local keep_previous="${MOLE_JETBRAINS_TOOLBOX_KEEP:-1}"
    [[ "$keep_previous" =~ ^[0-9]+$ ]] || keep_previous=1

    # Save and filter whitelist patterns for toolbox path
    local whitelist_overridden="false"
    local -a original_whitelist=()
    if [[ ${#WHITELIST_PATTERNS[@]} -gt 0 ]]; then
        original_whitelist=("${WHITELIST_PATTERNS[@]}")
        local -a filtered_whitelist=()
        local pattern
        for pattern in "${WHITELIST_PATTERNS[@]}"; do
            [[ "$toolbox_root" == "$pattern" || "$pattern" == "$toolbox_root"* ]] && continue
            filtered_whitelist+=("$pattern")
        done
        WHITELIST_PATTERNS=("${filtered_whitelist[@]+${filtered_whitelist[@]}}")
        whitelist_overridden="true"
    fi

    # Helper to restore whitelist on exit
    _restore_whitelist() {
        [[ "$whitelist_overridden" == "true" ]] && WHITELIST_PATTERNS=("${original_whitelist[@]}")
        return 0
    }

    local -a product_dirs=()
    while IFS= read -r -d '' product_dir; do
        product_dirs+=("$product_dir")
    done < <(command find "$toolbox_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)

    if [[ ${#product_dirs[@]} -eq 0 ]]; then
        _restore_whitelist
        return 0
    fi

    local product_dir
    for product_dir in "${product_dirs[@]}"; do
        while IFS= read -r -d '' channel_dir; do
            local current_link=""
            local current_real=""
            if [[ -L "$channel_dir/current" ]]; then
                current_link=$(readlink "$channel_dir/current" 2> /dev/null || true)
                if [[ -n "$current_link" ]]; then
                    if [[ "$current_link" == /* ]]; then
                        current_real="$current_link"
                    else
                        current_real="$channel_dir/$current_link"
                    fi
                fi
            elif [[ -d "$channel_dir/current" ]]; then
                current_real="$channel_dir/current"
            fi

            local -a version_dirs=()
            while IFS= read -r -d '' version_dir; do
                local name
                name=$(basename "$version_dir")

                [[ "$name" == "current" ]] && continue
                [[ "$name" == .* ]] && continue
                [[ "$name" == "plugins" || "$name" == "plugins-lib" || "$name" == "plugins-libs" ]] && continue
                [[ -n "$current_real" && "$version_dir" == "$current_real" ]] && continue
                [[ ! "$name" =~ ^[0-9] ]] && continue

                version_dirs+=("$version_dir")
            done < <(command find "$channel_dir" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)

            [[ ${#version_dirs[@]} -eq 0 ]] && continue

            local -a sorted_dirs=()
            while IFS= read -r line; do
                local dir_path="${line#* }"
                sorted_dirs+=("$dir_path")
            done < <(
                for version_dir in "${version_dirs[@]}"; do
                    local mtime
                    mtime=$(stat -f%m "$version_dir" 2> /dev/null || echo "0")
                    printf '%s %s\n' "$mtime" "$version_dir"
                done | sort -rn
            )

            if [[ ${#sorted_dirs[@]} -le "$keep_previous" ]]; then
                continue
            fi

            local idx=0
            local dir_path
            for dir_path in "${sorted_dirs[@]}"; do
                if [[ $idx -lt $keep_previous ]]; then
                    idx=$((idx + 1))
                    continue
                fi
                safe_clean "$dir_path" "JetBrains Toolbox old IDE version"
                note_activity
                idx=$((idx + 1))
            done
        done < <(command find "$product_dir" -mindepth 1 -maxdepth 1 -type d -name "ch-*" -print0 2> /dev/null)
    done

    _restore_whitelist
}

# JetBrains IDE logs are safe to rebuild, unlike some cache subtrees that can
# invalidate IDE indexes and trigger expensive reindexing.
clean_dev_jetbrains_logs() {
    safe_clean ~/Library/Logs/JetBrains/* "JetBrains IDE logs"
}

# AI coding agents (Claude Code, Cursor Agent, etc.) auto-update but never
# remove previous versions, so ~/.local/share/<agent>/versions accumulates
# hundreds of MB per release. Keep the most recently modified N entries
# plus the version pointed at by the active CLI symlink (mtime alone is
# unreliable: Claude Code pre-downloads the next version before flipping
# the symlink, so newest mtime is not always the active version).
_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS=()
_MOLE_VERSIONED_AGENT_RETENTION_TARGETS=()
_MOLE_VERSIONED_AGENT_ACTIVE_PATH=""

_versioned_agent_scan_deadline() {
    local timeout_seconds="${1:-$MOLE_TIMEOUT_DISK_VERIFY_SEC}"
    [[ "$timeout_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]] || timeout_seconds="$MOLE_TIMEOUT_DISK_VERIFY_SEC"
    local timeout_whole="${timeout_seconds%%.*}"
    local timeout_budget=$((10#$timeout_whole))
    if [[ "$timeout_seconds" == *.* && "${timeout_seconds#*.}" =~ [1-9] ]]; then
        timeout_budget=$((timeout_budget + 1))
    fi
    [[ $timeout_budget -gt 0 ]] || timeout_budget=1
    printf '%s\n' "$((SECONDS + timeout_budget))"
}

_materialize_versioned_agent_entries() {
    local versions_root="$1"
    local output_file="$2"
    local timeout_seconds="${3:-$MOLE_TIMEOUT_DISK_VERIFY_SEC}"
    : > "$output_file" || return 1

    local scan_rc=0
    run_with_timeout "$timeout_seconds" find "$versions_root" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type d \) -print0 \
        < /dev/null > "$output_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
    return 0
}

_versioned_agent_entry_mtime() {
    local entry="$1"
    local timeout_seconds="$2"
    run_with_timeout "$timeout_seconds" stat \
        -f%m "$entry" < /dev/null 2> /dev/null
}

_plan_versioned_agent_cleanup_targets() {
    local versions_root="$1"
    local keep_previous="$2"
    local active_path="${3:-}"

    _MOLE_VERSIONED_AGENT_CLEANUP_TARGETS=()
    _MOLE_VERSIONED_AGENT_RETENTION_TARGETS=()

    [[ -d "$versions_root" ]] || return 0

    local -a entries=()
    local -a entry_mtimes=()
    local scan_deadline=""
    scan_deadline=$(_versioned_agent_scan_deadline)
    local scan_timeout=""
    local deadline_rc=0
    scan_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$scan_deadline") || deadline_rc=$?
    [[ $deadline_rc -eq 0 ]] || return "$deadline_rc"
    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    _materialize_versioned_agent_entries \
        "$versions_root" "$scan_file" "$scan_timeout" || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    local entry
    local inventory_rc=0
    while IFS= read -r -d '' entry; do
        local name
        name=$(basename "$entry")
        [[ "$name" == .* ]] && continue
        [[ ! "$name" =~ ^[0-9] ]] && continue
        entries+=("$entry")
        local mtime=""
        local stat_rc=0
        local stat_timeout=""
        stat_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$scan_deadline") || stat_rc=$?
        if [[ $stat_rc -eq 0 ]]; then
            mtime=$(_versioned_agent_entry_mtime \
                "$entry" "$stat_timeout") || stat_rc=$?
        fi
        if [[ $stat_rc -ne 0 || ! "$mtime" =~ ^[0-9]+$ ]]; then
            inventory_rc=$stat_rc
            [[ $inventory_rc -ne 0 ]] || inventory_rc=1
            break
        fi
        entry_mtimes+=("$mtime")
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    if [[ $inventory_rc -ne 0 ]]; then
        _MOLE_VERSIONED_AGENT_CLEANUP_TARGETS=()
        _MOLE_VERSIONED_AGENT_RETENTION_TARGETS=()
        return "$inventory_rc"
    fi

    [[ ${#entries[@]} -le "$keep_previous" ]] && return 0

    # Sort the parallel arrays by mtime without serializing pathnames through
    # newline-delimited text. Version directories can legally contain newlines.
    local i j key_mtime key_path
    for ((i = 1; i < ${#entries[@]}; i++)); do
        key_path="${entries[$i]}"
        key_mtime="${entry_mtimes[$i]}"
        j=$((i - 1))
        while [[ $j -ge 0 && ${entry_mtimes[$j]} -lt $key_mtime ]]; do
            entries[j + 1]="${entries[$j]}"
            entry_mtimes[j + 1]="${entry_mtimes[$j]}"
            j=$((j - 1))
        done
        entries[j + 1]="$key_path"
        entry_mtimes[j + 1]="$key_mtime"
    done

    local idx=0
    local target
    for target in "${entries[@]}"; do
        if [[ -n "$active_path" && "$target" == "$active_path" ]]; then
            continue
        fi
        if [[ $idx -lt $keep_previous ]]; then
            idx=$((idx + 1))
            continue
        fi
        _MOLE_VERSIONED_AGENT_RETENTION_TARGETS+=("$target")
        if mole_cleanup_targets_exist "$target"; then
            _MOLE_VERSIONED_AGENT_CLEANUP_TARGETS+=("$target")
        fi
        idx=$((idx + 1))
    done
}

_resolve_versioned_agent_active_path() {
    local versions_root="$1"
    local active_symlink="$2"
    _MOLE_VERSIONED_AGENT_ACTIVE_PATH=""

    [[ -L "$active_symlink" ]] || return 1
    [[ -e "$active_symlink" ]] || return 2

    local target
    target=$(readlink "$active_symlink" 2> /dev/null || true)
    [[ -n "$target" ]] || return 2
    case "$target" in
        /*) ;;
        *) target="$(dirname "$active_symlink")/$target" ;;
    esac

    # Resolve dot segments and symlinked parent directories before comparing.
    # Launchers commonly use ../../relative targets, and a lexical comparison
    # would fail to pin the active version.
    local target_parent target_name
    target_parent=$(dirname "$target")
    target_name=$(basename "$target")
    target_parent=$(cd "$target_parent" 2> /dev/null && pwd -P) || return 2
    target="$target_parent/$target_name"

    local scan_deadline=""
    scan_deadline=$(_versioned_agent_scan_deadline)
    local scan_timeout=""
    local deadline_rc=0
    scan_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$scan_deadline") || deadline_rc=$?
    [[ $deadline_rc -eq 0 ]] || return "$deadline_rc"
    local scan_file=""
    scan_file=$(create_temp_file) || return 2
    local scan_rc=0
    _materialize_versioned_agent_entries \
        "$versions_root" "$scan_file" "$scan_timeout" || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    local entry entry_resolved entry_parent entry_name
    local found_active=false
    while IFS= read -r -d '' entry; do
        if [[ -d "$entry" ]]; then
            entry_resolved=$(cd "$entry" 2> /dev/null && pwd -P) || continue
        else
            entry_parent=$(dirname "$entry")
            entry_name=$(basename "$entry")
            entry_parent=$(cd "$entry_parent" 2> /dev/null && pwd -P) || continue
            entry_resolved="$entry_parent/$entry_name"
        fi
        case "$target/" in
            "$entry_resolved"/*)
                _MOLE_VERSIONED_AGENT_ACTIVE_PATH="$entry"
                found_active=true
                break
                ;;
        esac
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    [[ "$found_active" == "true" ]] && return 0
    return 2
}

_MOLE_VERSIONED_AGENT_GUARD_ROOT=""
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK=""
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=false
_MOLE_VERSIONED_AGENT_GUARD_KEEP=1
_MOLE_CLEAN_GUARD_REASON=""

_versioned_agent_delete_guard_allows() {
    local target="${1:-}"
    local active_path=""
    local active_status=0

    if [[ -n "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK" ]]; then
        _resolve_versioned_agent_active_path \
            "$_MOLE_VERSIONED_AGENT_GUARD_ROOT" \
            "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK" || active_status=$?
        if [[ $active_status -eq 124 || $active_status -ge 128 ]]; then
            _MOLE_CLEAN_GUARD_REASON="inventory interrupted"
            return "$active_status"
        fi
        if [[ $active_status -eq 0 ]]; then
            active_path="$_MOLE_VERSIONED_AGENT_ACTIVE_PATH"
        elif [[ $active_status -eq 1 && "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED" != "true" ]]; then
            : # This agent currently has no active launcher symlink to preserve.
        elif [[ $active_status -eq 1 ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version changed"
            return 1
        else
            _MOLE_CLEAN_GUARD_REASON="active version unknown"
            return "$active_status"
        fi
    fi

    # An updater can switch the launcher or install a newer version while size
    # is being measured. Re-plan and authorize this exact target at the delete
    # boundary so neither the active version nor the new retention set is lost.
    local plan_rc=0
    _plan_versioned_agent_cleanup_targets \
        "$_MOLE_VERSIONED_AGENT_GUARD_ROOT" \
        "$_MOLE_VERSIONED_AGENT_GUARD_KEEP" \
        "$active_path" || plan_rc=$?
    if [[ $plan_rc -ne 0 ]]; then
        _MOLE_CLEAN_GUARD_REASON="inventory unknown"
        [[ $plan_rc -eq 124 || $plan_rc -ge 128 ]] && return "$plan_rc"
        return 1
    fi

    if [[ -n "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK" ]]; then
        local verified_active_path=""
        local verified_active_status=0
        _resolve_versioned_agent_active_path \
            "$_MOLE_VERSIONED_AGENT_GUARD_ROOT" \
            "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK" || verified_active_status=$?
        if [[ $verified_active_status -eq 124 || $verified_active_status -ge 128 ]]; then
            _MOLE_CLEAN_GUARD_REASON="inventory interrupted"
            return "$verified_active_status"
        fi
        [[ $verified_active_status -ne 0 ]] || verified_active_path="$_MOLE_VERSIONED_AGENT_ACTIVE_PATH"
        if [[ $verified_active_status -ne 0 && $verified_active_status -ne 1 ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version unknown"
            return "$verified_active_status"
        fi
        if [[ $verified_active_status -eq 1 && "$_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED" == "true" ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version changed"
            return 1
        fi
        if [[ $verified_active_status -ne $active_status || "$verified_active_path" != "$active_path" ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version changed"
            return 1
        fi
    fi

    local planned_target
    if [[ ${#_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS[@]} -gt 0 ]]; then
        for planned_target in "${_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS[@]}"; do
            [[ "$planned_target" == "$target" ]] && return 0
        done
    fi

    _MOLE_CLEAN_GUARD_REASON="retention changed"
    return 1
}

_report_versioned_agent_guard_stop() {
    local label="$1"
    echo -e "  ${GRAY}${ICON_WARNING}${NC} ${label} · stopped (${_MOLE_CLEAN_GUARD_REASON})"
    note_activity
}

clean_versioned_agent_root() {
    local versions_root="$1"
    local label="$2"
    local keep_previous="$3"
    local active_path="${4:-}"
    local active_symlink="${5:-}"

    local plan_rc=0
    _plan_versioned_agent_cleanup_targets \
        "$versions_root" "$keep_previous" "$active_path" || plan_rc=$?
    if [[ $plan_rc -ne 0 ]]; then
        _MOLE_CLEAN_GUARD_REASON="inventory unknown"
        [[ $plan_rc -eq 124 || $plan_rc -ge 128 ]] && return "$plan_rc"
        _report_versioned_agent_guard_stop "$label"
        return "$plan_rc"
    fi
    [[ ${#_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]} -gt 0 ]] || return 0

    _MOLE_VERSIONED_AGENT_GUARD_ROOT="$versions_root"
    _MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK="$active_symlink"
    _MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=false
    [[ -n "$active_path" ]] && _MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=true
    _MOLE_VERSIONED_AGENT_GUARD_KEEP="$keep_previous"
    _MOLE_CLEAN_GUARD_REASON="retention changed"

    if declare -f safe_clean_guarded > /dev/null 2>&1; then
        local guarded_rc=0
        safe_clean_guarded \
            _versioned_agent_delete_guard_allows \
            "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}" \
            "$label" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            _report_versioned_agent_guard_stop "$label"
            return 0
        fi
        return "$guarded_rc"
    fi

    local target
    for target in "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}"; do
        local guard_rc=0
        _versioned_agent_delete_guard_allows "$target" || guard_rc=$?
        if [[ $guard_rc -ne 0 ]]; then
            [[ $guard_rc -eq 124 || $guard_rc -ge 128 ]] && return "$guard_rc"
            _report_versioned_agent_guard_stop "$label"
            return 0
        fi
        safe_clean "$target" "$label"
        note_activity
    done
}

count_versioned_agent_entries() {
    local versions_root="$1"
    local count=0
    local entry

    [[ -d "$versions_root" ]] || {
        echo 0
        return 0
    }

    local scan_timeout="$MOLE_TIMEOUT_DISK_VERIFY_SEC"
    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    _materialize_versioned_agent_entries \
        "$versions_root" "$scan_file" "$scan_timeout" || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    while IFS= read -r -d '' entry; do
        local name
        name=$(basename "$entry")
        [[ "$name" == .* ]] && continue
        [[ ! "$name" =~ ^[0-9] ]] && continue
        count=$((count + 1))
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    echo "$count"
}

claude_desktop_sdk_version_is_safe() {
    local sdk_version="${1:-}"

    [[ -n "$sdk_version" ]] || return 1
    [[ "$sdk_version" == .* ]] && return 1
    [[ "$sdk_version" == *"/"* ]] && return 1
    [[ "$sdk_version" == *".."* ]] && return 1
    [[ "$sdk_version" =~ ^[0-9] ]] || return 1
    return 0
}

claude_desktop_running() {
    mole_pgrep_any \
        -x "Claude" \
        -f "/Claude.app/"
}

claude_desktop_sdk_version() {
    local claude_support="$1"
    local sdk_file="$claude_support/claude-code-vm/.sdk-version"
    [[ -f "$sdk_file" ]] || return 1

    local sdk_version
    sdk_version=$(head -n 1 "$sdk_file" 2> /dev/null | LC_ALL=C tr -d '[:space:]' || true)
    claude_desktop_sdk_version_is_safe "$sdk_version" || return 1

    printf '%s\n' "$sdk_version"
}

_MOLE_CLAUDE_DESKTOP_GUARD_SUPPORT=""
_MOLE_CLAUDE_DESKTOP_GUARD_SDK_VERSION=""
_MOLE_CLAUDE_DESKTOP_GUARD_VERSIONS_ROOT=""
_MOLE_CLAUDE_DESKTOP_GUARD_CLI_ROOT=""
_MOLE_CLAUDE_DESKTOP_GUARD_VM_ROOT=""
_MOLE_CLAUDE_DESKTOP_GUARD_KEEP=1
_MOLE_CLEAN_GUARD_REASON=""

_claude_desktop_delete_guard_allows() {
    local target="${1:-}"
    mole_clean_process_guard claude_desktop_running "Claude Desktop started" || return 1

    local current_sdk=""
    current_sdk=$(claude_desktop_sdk_version "$_MOLE_CLAUDE_DESKTOP_GUARD_SUPPORT" || true)
    if [[ -z "$current_sdk" || "$current_sdk" != "$_MOLE_CLAUDE_DESKTOP_GUARD_SDK_VERSION" ]]; then
        _MOLE_CLEAN_GUARD_REASON="active version changed"
        return 1
    fi

    local active_root active_entry
    for active_root in \
        "$_MOLE_CLAUDE_DESKTOP_GUARD_CLI_ROOT" \
        "$_MOLE_CLAUDE_DESKTOP_GUARD_VM_ROOT"; do
        [[ -n "$active_root" ]] || continue
        active_entry="$active_root/$current_sdk"
        if [[ -L "$active_entry" || (! -f "$active_entry" && ! -d "$active_entry") ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version changed"
            return 1
        fi
    done

    # A staged update can change which previous version retention should keep
    # while size is being measured. Re-plan and authorize this exact target.
    local plan_rc=0
    _plan_versioned_agent_cleanup_targets \
        "$_MOLE_CLAUDE_DESKTOP_GUARD_VERSIONS_ROOT" \
        "$_MOLE_CLAUDE_DESKTOP_GUARD_KEEP" \
        "$_MOLE_CLAUDE_DESKTOP_GUARD_VERSIONS_ROOT/$current_sdk" || plan_rc=$?
    if [[ $plan_rc -ne 0 ]]; then
        _MOLE_CLEAN_GUARD_REASON="inventory unknown"
        [[ $plan_rc -eq 124 || $plan_rc -ge 128 ]] && return "$plan_rc"
        return 1
    fi

    # Re-read the SDK marker and active entries after retention planning. The
    # planner walks and stats every version, which gives an updater time to
    # switch the active SDK after the first evidence check.
    local verified_sdk=""
    verified_sdk=$(claude_desktop_sdk_version "$_MOLE_CLAUDE_DESKTOP_GUARD_SUPPORT" || true)
    if [[ -z "$verified_sdk" || "$verified_sdk" != "$current_sdk" ]]; then
        _MOLE_CLEAN_GUARD_REASON="active version changed"
        return 1
    fi
    for active_root in \
        "$_MOLE_CLAUDE_DESKTOP_GUARD_CLI_ROOT" \
        "$_MOLE_CLAUDE_DESKTOP_GUARD_VM_ROOT"; do
        [[ -n "$active_root" ]] || continue
        active_entry="$active_root/$verified_sdk"
        if [[ -L "$active_entry" || (! -f "$active_entry" && ! -d "$active_entry") ]]; then
            _MOLE_CLEAN_GUARD_REASON="active version changed"
            return 1
        fi
    done

    local planned_target
    if [[ ${#_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS[@]} -gt 0 ]]; then
        for planned_target in "${_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS[@]}"; do
            [[ "$planned_target" == "$target" ]] && return 0
        done
    fi

    _MOLE_CLEAN_GUARD_REASON="retention changed"
    return 1
}

_claude_desktop_safe_clean_guarded() {
    local display_name="$1"
    shift
    _MOLE_CLEAN_GUARD_REASON="process state changed"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        local -a cleanup_args=("$@")
        local cleanup_arg_count=${#cleanup_args[@]}
        [[ $cleanup_arg_count -gt 1 ]] || return 0
        local description="${cleanup_args[$((cleanup_arg_count - 1))]}"
        local index target
        for ((index = 0; index < cleanup_arg_count - 1; index++)); do
            target="${cleanup_args[$index]}"
            local guard_rc=0
            _claude_desktop_delete_guard_allows "$target" || guard_rc=$?
            if [[ $guard_rc -ne 0 ]]; then
                [[ $guard_rc -eq 124 || $guard_rc -ge 128 ]] && return "$guard_rc"
                if [[ "$_MOLE_CLEAN_GUARD_REASON" == "Claude Desktop started" ]]; then
                    mole_defer_cleanup_family "Claude Desktop"
                else
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${_MOLE_CLEAN_GUARD_REASON})"
                    note_activity
                fi
                return 1
            fi
            safe_clean "$target" "$description" || return $?
        done
        return 0
    fi

    local guarded_rc=0
    safe_clean_guarded _claude_desktop_delete_guard_allows "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        if [[ "$_MOLE_CLEAN_GUARD_REASON" == "Claude Desktop started" ]]; then
            mole_defer_cleanup_family "Claude Desktop"
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · stopped (${_MOLE_CLEAN_GUARD_REASON})"
            note_activity
        fi
        return 1
    fi
    return "$guarded_rc"
}

_deny_versioned_agent_delete() {
    return 1
}

clean_claude_desktop_bundled_versions() {
    local keep_previous="$1"
    local claude_support="$HOME/Library/Application Support/Claude"
    [[ -d "$claude_support" ]] || return 0
    _MOLE_CLAUDE_DESKTOP_GUARD_CLI_ROOT=""
    _MOLE_CLAUDE_DESKTOP_GUARD_VM_ROOT=""

    local -a desktop_specs=(
        "$claude_support/claude-code|Claude Desktop bundled Claude Code old version"
        "$claude_support/claude-code-vm|Claude Desktop bundled Claude Code VM old version"
    )

    local has_multiple_versions=false
    local spec
    for spec in "${desktop_specs[@]}"; do
        local versions_root="${spec%%|*}"
        [[ -d "$versions_root" ]] || continue

        local version_count=""
        local count_rc=0
        version_count=$(count_versioned_agent_entries "$versions_root") || count_rc=$?
        [[ $count_rc -eq 0 ]] || return "$count_rc"
        [[ "$version_count" =~ ^[0-9]+$ ]] || return 1
        if [[ "$version_count" -gt 1 ]]; then
            has_multiple_versions=true
            break
        fi
    done

    [[ "$has_multiple_versions" == "true" ]] || return 0

    local sdk_version=""
    sdk_version=$(claude_desktop_sdk_version "$claude_support" || true)
    if [[ -z "$sdk_version" ]]; then
        note_activity
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Claude Desktop bundled Claude Code · skipped (active version unknown)"
        return 0
    fi

    for spec in "${desktop_specs[@]}"; do
        local versions_root="${spec%%|*}"
        local label="${spec#*|}"
        [[ -d "$versions_root" ]] || continue

        local active_entry="$versions_root/$sdk_version"
        if [[ -L "$active_entry" || (! -f "$active_entry" && ! -d "$active_entry") ]]; then
            note_activity
            echo -e "  ${GRAY}${ICON_WARNING}${NC} $label · skipped (active version unknown)"
            return 0
        fi
    done

    [[ -d "$claude_support/claude-code" ]] && _MOLE_CLAUDE_DESKTOP_GUARD_CLI_ROOT="$claude_support/claude-code"
    [[ -d "$claude_support/claude-code-vm" ]] && _MOLE_CLAUDE_DESKTOP_GUARD_VM_ROOT="$claude_support/claude-code-vm"

    # Confirm at least one exact, unprotected stale version exists before the
    # process gate. Multiple directories alone are insufficient when retention
    # keeps them all or policy excludes every old entry.
    local has_cleanup_target=false
    local has_retention_target=false
    for spec in "${desktop_specs[@]}"; do
        local versions_root="${spec%%|*}"
        [[ -d "$versions_root" ]] || continue
        local plan_rc=0
        _plan_versioned_agent_cleanup_targets \
            "$versions_root" "$keep_previous" "$versions_root/$sdk_version" || plan_rc=$?
        [[ $plan_rc -eq 0 ]] || return "$plan_rc"
        if [[ ${#_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]} -gt 0 ]]; then
            has_retention_target=true
        fi
        if [[ ${#_MOLE_VERSIONED_AGENT_CLEANUP_TARGETS[@]} -gt 0 ]]; then
            has_cleanup_target=true
            break
        fi
    done
    [[ "$has_retention_target" == "true" ]] || return 0

    # Preserve safe_clean's skip logging/counters for retention-selected paths
    # even when policy currently excludes every target. The deny guard prevents
    # a policy-changing race from turning this accounting pass into deletion.
    if [[ "$has_cleanup_target" != "true" ]]; then
        for spec in "${desktop_specs[@]}"; do
            local versions_root="${spec%%|*}"
            local label="${spec#*|}"
            [[ -d "$versions_root" ]] || continue
            local plan_rc=0
            _plan_versioned_agent_cleanup_targets \
                "$versions_root" "$keep_previous" "$versions_root/$sdk_version" || plan_rc=$?
            [[ $plan_rc -eq 0 ]] || return "$plan_rc"
            [[ ${#_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]} -gt 0 ]] || continue
            if declare -f safe_clean_guarded > /dev/null 2>&1; then
                safe_clean_guarded \
                    _deny_versioned_agent_delete \
                    "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}" \
                    "$label" > /dev/null || true
            else
                safe_clean "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}" "$label"
            fi
        done
        return 0
    fi

    local process_state=0
    claude_desktop_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Claude Desktop bundled Claude Code · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Claude Desktop"
        fi
        return 0
    fi

    for spec in "${desktop_specs[@]}"; do
        local versions_root="${spec%%|*}"
        local label="${spec#*|}"
        [[ -d "$versions_root" ]] || continue

        local version_count=""
        local count_rc=0
        version_count=$(count_versioned_agent_entries "$versions_root") || count_rc=$?
        [[ $count_rc -eq 0 ]] || return "$count_rc"
        [[ "$version_count" =~ ^[0-9]+$ ]] || return 1
        [[ "$version_count" -le 1 ]] && continue

        local plan_rc=0
        _plan_versioned_agent_cleanup_targets \
            "$versions_root" "$keep_previous" "$versions_root/$sdk_version" || plan_rc=$?
        [[ $plan_rc -eq 0 ]] || return "$plan_rc"
        [[ ${#_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]} -gt 0 ]] || continue

        _MOLE_CLAUDE_DESKTOP_GUARD_SUPPORT="$claude_support"
        _MOLE_CLAUDE_DESKTOP_GUARD_SDK_VERSION="$sdk_version"
        _MOLE_CLAUDE_DESKTOP_GUARD_VERSIONS_ROOT="$versions_root"
        _MOLE_CLAUDE_DESKTOP_GUARD_KEEP="$keep_previous"
        local clean_rc=0
        _claude_desktop_safe_clean_guarded \
            "$label" \
            "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}" \
            "$label" || clean_rc=$?
        [[ $clean_rc -eq 0 || $clean_rc -eq 1 ]] || return "$clean_rc"
    done
}

# Headless browser trees leaked by dead Playwright/agent automation sessions.
# When an MCP server or agent harness dies without cleanup, its browser
# daemons reparent to launchd (ppid 1) and the Chrome tree keeps running
# headless, holding RSS; the ephemeral temp profiles keep disk.
#
# Only processes tied to playwright_chromiumdev_profile-* automation profiles
# are ever touched, never a user's real browser, and the evidence of a leak is
# ppid 1: the harness that owned this browser is gone. That is a fact about
# the session rather than a guess from age, so it protects a live automation
# run of any length (its parent is still alive) while catching a leak minutes
# after it happens instead of a day later. The one-hour floor only keeps the
# scan away from a browser that is mid-handoff between two parents.
#
# Chrome helper processes keep the main browser as their parent, so this
# matches roots only and the tree follows them down.
_automation_browser_process_records() {
    local wanted_pid="${1:-}"
    awk -v wanted_pid="$wanted_pid" '
        NF < 9 { next }
        $1 !~ /^[0-9]+$/ { next }
        wanted_pid != "" && $1 != wanted_pid { next }
        $2 != 1 { next }
        # ps prints mm:ss below an hour and hh:mm:ss or dd-hh:mm:ss above it.
        $3 !~ /-/ && $3 !~ /^[0-9]+:[0-9][0-9]:[0-9][0-9]$/ { next }
        {
            command = $9
            for (i = 10; i <= NF; i++) command = command " " $i
        }
        command ~ /playwright-core\/lib\/entry\/cliDaemon\.js/ ||
            command ~ /playwright_chromiumdev_profile/ {
            print $1 "|" $4 " " $5 " " $6 " " $7 " " $8
        }'
}

_automation_browser_process_matches_record() {
    local pid="$1"
    local expected_start="$2"
    [[ "$pid" =~ ^[0-9]+$ && -n "$expected_start" ]] || return 1

    local process_row=""
    local ps_rc=0
    process_row=$(LC_ALL=C run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        ps -p "$pid" -o pid=,ppid=,etime=,lstart=,command= -ww 2> /dev/null) || ps_rc=$?
    [[ $ps_rc -eq 0 ]] || return "$ps_rc"

    local current_record=""
    current_record=$(printf '%s\n' "$process_row" |
        _automation_browser_process_records "$pid") || return 1
    [[ "$current_record" == "$pid|$expected_start" ]]
}

clean_dev_automation_browsers() {
    local -a leaked_processes=()
    local process_rows=""
    local ps_rc=0
    process_rows=$(LC_ALL=C run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        ps -Ao pid=,ppid=,etime=,lstart=,command= -ww 2> /dev/null) || ps_rc=$?
    if [[ $ps_rc -eq 124 || $ps_rc -ge 128 ]]; then
        return "$ps_rc"
    elif [[ $ps_rc -eq 0 ]]; then
        local process_record
        while IFS= read -r process_record; do
            [[ -n "$process_record" ]] && leaked_processes+=("$process_record")
        done < <(printf '%s\n' "$process_rows" | _automation_browser_process_records | sort -n)
    fi

    # Ephemeral automation profiles: stale after 2h, and never one that a
    # live process still references.
    local -a stale_profiles=()
    local tmpdir
    tmpdir=$(getconf DARWIN_USER_TEMP_DIR 2> /dev/null) || tmpdir=""
    if [[ -n "$tmpdir" ]]; then
        local d now age_hours
        now=$(date +%s)
        for d in "$tmpdir"playwright_chromiumdev_profile-*; do
            [[ -d "$d" ]] || continue
            age_hours=$(((now - $(stat -f %m "$d" 2> /dev/null || echo "$now")) / 3600))
            [[ "$age_hours" -ge 2 ]] || continue
            pgrep -qf "$d" 2> /dev/null && continue
            stale_profiles+=("$d")
        done
    fi

    if [[ ${#leaked_processes[@]} -gt 0 ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Leaked automation browsers · would stop ${#leaked_processes[@]} processes ${YELLOW}dry${NC}"
        else
            local stopped=0
            local -a term_processes=()
            local pid expected_start match_rc
            for process_record in "${leaked_processes[@]}"; do
                pid="${process_record%%|*}"
                expected_start="${process_record#*|}"
                match_rc=0
                _automation_browser_process_matches_record \
                    "$pid" "$expected_start" || match_rc=$?
                if [[ $match_rc -eq 124 || $match_rc -ge 128 ]]; then
                    return "$match_rc"
                elif [[ $match_rc -ne 0 ]]; then
                    continue
                fi
                if kill -TERM "$pid" 2> /dev/null; then
                    stopped=$((stopped + 1))
                    term_processes+=("$process_record")
                fi
            done
            if [[ ${#term_processes[@]} -gt 0 ]]; then
                sleep 1
                # Escalate only when the same process still owns the PID and
                # still has the orphaned automation-browser evidence.
                for process_record in "${term_processes[@]}"; do
                    pid="${process_record%%|*}"
                    expected_start="${process_record#*|}"
                    match_rc=0
                    _automation_browser_process_matches_record \
                        "$pid" "$expected_start" || match_rc=$?
                    if [[ $match_rc -eq 124 || $match_rc -ge 128 ]]; then
                        return "$match_rc"
                    elif [[ $match_rc -eq 0 ]]; then
                        kill -9 "$pid" 2> /dev/null || true
                    fi
                done
            fi
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Leaked automation browsers · stopped ${stopped} processes"
        fi
        note_activity
    fi

    if [[ ${#stale_profiles[@]} -gt 0 ]]; then
        safe_clean "${stale_profiles[@]}" "Leaked browser profiles" || return $?
    fi
    return 0
}

clean_dev_ai_agents() {
    local keep_previous="${MOLE_AI_AGENTS_KEEP:-1}"
    [[ "$keep_previous" =~ ^[0-9]+$ ]] || keep_previous=1

    local -a agent_specs=(
        "$HOME/.local/share/claude/versions|Claude Code old version|$HOME/.local/bin/claude"
        "$HOME/.local/share/cursor-agent/versions|Cursor Agent old version|$HOME/.local/bin/cursor-agent"
        "$HOME/.copilot/pkg/universal|GitHub Copilot CLI old version|$HOME/.local/bin/copilot"
    )

    local spec
    for spec in "${agent_specs[@]}"; do
        local versions_root="${spec%%|*}"
        local rest="${spec#*|}"
        local label="${rest%%|*}"
        local active_symlink="${rest#*|}"
        [[ "$active_symlink" == "$rest" ]] && active_symlink=""
        [[ -d "$versions_root" ]] || continue

        local active_path=""
        if [[ -n "$active_symlink" && -L "$active_symlink" ]]; then
            local active_status=0
            _resolve_versioned_agent_active_path "$versions_root" "$active_symlink" || active_status=$?
            if [[ $active_status -ne 0 ]]; then
                [[ $active_status -eq 124 || $active_status -ge 128 ]] && return "$active_status"
                if [[ ! -e "$active_symlink" ]]; then
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} $label · skipped (active symlink broken)"
                else
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} $label · skipped (active version unknown)"
                fi
                note_activity
                continue
            fi
            active_path="$_MOLE_VERSIONED_AGENT_ACTIVE_PATH"
            if [[ -z "$active_path" ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} $label · skipped (active symlink broken)"
                note_activity
                continue
            fi
        fi

        clean_versioned_agent_root \
            "$versions_root" "$label" "$keep_previous" "$active_path" "$active_symlink" || return $?
    done

    clean_claude_desktop_bundled_versions "$keep_previous"
}

# Other language tool caches.
clean_dev_other_langs() {
    safe_clean ~/.composer/cache/* "PHP Composer cache (legacy)"
    safe_clean ~/Library/Caches/composer/* "PHP Composer cache"
    # ~/.nuget/packages is NuGet's global packages folder, the restore target
    # itself rather than an HTTP cache, so it is the .NET equivalent of
    # ~/.m2/repository: emptying it forces a full re-download on the next
    # build. Both stay off the delete path and are surfaced by
    # `clean_large_files` for review instead.
    # safe_clean ~/.pub-cache/* "Dart Pub cache"
    safe_clean ~/.cache/bazel/* "Bazel cache"
    safe_clean ~/.cache/zig/* "Zig cache"
    # DENO_DIR mixes remote imports with origin storage and downloaded runtime
    # payloads. The owner clean command resets the whole root, so Mole keeps it
    # review-only and the generic user-cache sweep excludes it as well.
    clean_clang_module_cache
}
# CI/CD and DevOps caches.
clean_dev_cicd() {
    safe_clean ~/.cache/terraform/* "Terraform cache"
    safe_clean ~/.grafana/cache/* "Grafana cache"
    safe_clean ~/.prometheus/data/wal/* "Prometheus WAL cache"
    safe_clean ~/.jenkins/workspace/*/target/* "Jenkins workspace cache"
    safe_clean ~/.cache/gitlab-runner/* "GitLab Runner cache"
    safe_clean ~/.github/cache/* "GitHub Actions cache"
    safe_clean ~/.circleci/cache/* "CircleCI cache"
    safe_clean ~/.sonar/* "SonarQube cache"
}
# Database tool caches.
clean_dev_database() {
    safe_clean ~/Library/Caches/com.sequel-ace.sequel-ace/* "Sequel Ace cache"
    safe_clean ~/Library/Caches/com.eggerapps.Sequel-Pro/* "Sequel Pro cache"
    safe_clean ~/Library/Caches/redis-desktop-manager/* "Redis Desktop Manager cache"
    safe_clean ~/Library/Caches/com.navicat.* "Navicat cache"
    safe_clean ~/Library/Caches/com.dbeaver.* "DBeaver cache"
    safe_clean ~/Library/Caches/com.redis.RedisInsight "Redis Insight cache"
}
# API/debugging tool caches.
clean_dev_api_tools() {
    safe_clean ~/Library/Caches/com.postmanlabs.mac/* "Postman cache"
    safe_clean ~/Library/Caches/com.konghq.insomnia/* "Insomnia cache"
    safe_clean ~/Library/Caches/com.tinyapp.TablePlus/* "TablePlus cache"
    safe_clean ~/Library/Caches/com.getpaw.Paw/* "Paw API cache"
    safe_clean ~/Library/Caches/com.charlesproxy.charles/* "Charles Proxy cache"
    safe_clean ~/Library/Caches/com.proxyman.NSProxy/* "Proxyman cache"
}

codex_desktop_process_state() {
    command -v pgrep > /dev/null 2>&1 || return 2

    local mode pattern probe_status
    while IFS='|' read -r mode pattern; do
        if pgrep "$mode" "$pattern" > /dev/null 2>&1; then
            return 0
        else
            probe_status=$?
            [[ $probe_status -eq 1 ]] || return 2
        fi
    done << 'EOF'
-x|Codex
-x|ChatGPT
-f|/Codex.app/
-f|/ChatGPT.app/
EOF
    return 1
}

codex_desktop_running() {
    local process_state=0
    codex_desktop_process_state || process_state=$?
    [[ $process_state -ne 1 ]]
}

codex_runtime_process_state() {
    local cli_state=0
    local desktop_state=0
    mole_pgrep_any -x "codex" || cli_state=$?
    codex_desktop_process_state || desktop_state=$?

    if [[ $cli_state -eq 0 || $desktop_state -eq 0 ]]; then
        return 0
    fi
    if [[ $cli_state -eq 1 && $desktop_state -eq 1 ]]; then
        return 1
    fi
    return 2
}

codex_desktop_cache_physical_path() {
    local candidate="$1"
    local cache_root="$HOME/Library/Caches/Codex"
    local home_prefix="${HOME%/}/"

    case "$candidate" in
        "$cache_root" | "$cache_root"/*) ;;
        *) return 1 ;;
    esac
    [[ -d "$candidate" ]] || return 1

    # Reject every symlink component below HOME before resolving paths. This is
    # deliberately local to Codex: global deletion validation still permits
    # legitimate platform aliases such as /tmp -> /private/tmp.
    local relative="${candidate#"$home_prefix"}"
    local old_ifs="$IFS"
    local -a components=()
    IFS='/' read -r -a components <<< "$relative"
    IFS="$old_ifs"
    [[ ${#components[@]} -gt 0 ]] || return 1

    local probe="$HOME"
    local component
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || return 1
        probe="$probe/$component"
        [[ -L "$probe" ]] && return 1
    done

    local physical_root=""
    local physical_candidate=""
    physical_root=$(cd -P "$cache_root" 2> /dev/null && pwd -P) || return 1
    physical_candidate=$(cd -P "$candidate" 2> /dev/null && pwd -P) || return 1
    case "$physical_candidate" in
        "$physical_root" | "$physical_root"/*)
            printf '%s\n' "$physical_candidate"
            return 0
            ;;
    esac
    return 1
}

_codex_desktop_cache_delete_guard_allows() {
    mole_clean_process_guard codex_desktop_process_state "Codex started"
}

_codex_desktop_safe_clean_guarded() {
    local display_name="$1"
    shift
    local _MOLE_CLEAN_GUARD_REASON="process state changed"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! _codex_desktop_cache_delete_guard_allows; then
            mole_report_guard_stop "$display_name" mole_defer_cleanup_family "Codex"
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded _codex_desktop_cache_delete_guard_allows "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        mole_report_guard_stop "$display_name" mole_defer_cleanup_family "Codex"
        return 1
    fi
    return "$guarded_rc"
}

clean_codex_desktop_caches() {
    local cache_root="$HOME/Library/Caches/Codex"
    [[ -d "$cache_root" ]] || return 0

    if ! codex_desktop_cache_physical_path "$cache_root" > /dev/null; then
        debug_log "Codex Desktop caches skipped: unsafe cache root"
        return 0
    fi

    # Measured on ChatGPT 26.727.40816: these six Chromium leaves reclaimed
    # 313,860 KiB. Local Storage, IndexedDB, cookies, sessions, preferences, and
    # every Application Support sibling are deliberate non-targets because they
    # can hold durable state rather than rebuildable cache data.
    local -a profiles=(
        "$cache_root/Default"
        "$cache_root/Default/Partitions/codex-browser-app"
        "$cache_root/codex-browser-app"
    )
    local -a leaves=("Cache" "Code Cache")
    local -a cleanable_physical_leaves=()
    local -a cleanable_leaf_labels=()
    local profile leaf physical_leaf
    for profile in "${profiles[@]}"; do
        for leaf in "${leaves[@]}"; do
            physical_leaf=""
            if physical_leaf=$(codex_desktop_cache_physical_path "$profile/$leaf"); then
                if mole_cleanup_targets_exist "$physical_leaf"/*; then
                    cleanable_physical_leaves+=("$physical_leaf")
                    cleanable_leaf_labels+=("$leaf")
                fi
            else
                debug_log "Codex Desktop cache leaf skipped: $profile/$leaf"
            fi
        done
    done
    [[ ${#cleanable_physical_leaves[@]} -gt 0 ]] || return 0

    local process_state=0
    codex_desktop_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex Desktop caches · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi

    local cleanable_index
    for ((cleanable_index = 0; cleanable_index < ${#cleanable_physical_leaves[@]}; cleanable_index++)); do
        physical_leaf="${cleanable_physical_leaves[$cleanable_index]}"
        leaf="${cleanable_leaf_labels[$cleanable_index]}"
        _codex_desktop_safe_clean_guarded \
            "Codex Desktop caches" \
            "$physical_leaf"/* \
            "Codex Desktop $leaf" || return 0
    done
}

codex_sparkle_updater_running() {
    mole_pgrep_any \
        -f "org[.]sparkle-project[.]Sparkle" \
        -f "Sparkle[.]framework/.*/(Autoupdate|Installer|Downloader|Updater)"
}

codex_sparkle_staging_has_open_files() {
    local staging_root="$1"
    local visibility_rc=0
    _mole_complete_lsof_mode || visibility_rc=$?
    if [[ $visibility_rc -eq 124 || $visibility_rc -ge 128 ]]; then
        return "$visibility_rc"
    fi
    [[ $visibility_rc -eq 0 ]] || return 2

    local lsof_output=""
    local lsof_error_file=""
    local lsof_rc=0
    lsof_error_file=$(create_temp_file 2> /dev/null || true)
    [[ -n "$lsof_error_file" && -f "$lsof_error_file" && ! -L "$lsof_error_file" ]] || return 2

    if lsof_output=$(_mole_run_complete_lsof "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -Fn +D "$staging_root" 2> "$lsof_error_file"); then
        [[ -n "$lsof_output" ]]
        return
    else
        lsof_rc=$?
    fi

    if [[ $lsof_rc -eq 124 || $lsof_rc -ge 128 ]]; then
        return "$lsof_rc"
    fi

    # `lsof +D` returns 1 when no open files match. Timeouts or other failures
    # are different. Some probe errors also return 1, so stderr must be empty
    # before treating that status as a reliable no-match.
    [[ "$lsof_rc" -eq 1 && ! -s "$lsof_error_file" ]] && return 1
    return 2
}

# Physical-path gate for a staging directory that must sit exactly one level
# under a fixed, app-owned root below HOME. Prints the resolved physical path,
# or fails when the candidate is outside the root, is not a directory, sits too
# deep, or reaches the root through a symlink. No component below HOME may be a
# link: these are fixed app-owned paths, and accepting one would let a lexical
# staging root be redirected into ordinary user data.
codex_staging_physical_path() {
    local candidate="$1"
    local staging_root="$2"
    local home_prefix="${HOME%/}/"

    case "$candidate" in
        "$staging_root" | "$staging_root"/*) ;;
        *) return 1 ;;
    esac
    [[ -d "$candidate" ]] || return 1
    if [[ "$candidate" != "$staging_root" && "${candidate%/*}" != "$staging_root" ]]; then
        return 1
    fi

    local relative="${candidate#"$home_prefix"}"
    local old_ifs="$IFS"
    local -a components=()
    IFS='/' read -r -a components <<< "$relative"
    IFS="$old_ifs"
    [[ ${#components[@]} -gt 0 ]] || return 1

    local probe="$HOME"
    local component
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || return 1
        probe="$probe/$component"
        [[ -L "$probe" ]] && return 1
    done

    local physical_root=""
    local physical_candidate=""
    physical_root=$(cd -P "$staging_root" 2> /dev/null && pwd -P) || return 1
    physical_candidate=$(cd -P "$candidate" 2> /dev/null && pwd -P) || return 1
    if [[ "$candidate" == "$staging_root" ]]; then
        [[ "$physical_candidate" == "$physical_root" ]] || return 1
    else
        [[ "${physical_candidate%/*}" == "$physical_root" ]] || return 1
    fi

    printf '%s\n' "$physical_candidate"
}

# Sparkle's staging root is fixed, so it only supplies the root.
codex_sparkle_staging_physical_path() {
    codex_staging_physical_path \
        "$1" "$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
}

_MOLE_CODEX_STAGING_ROOT=""
_MOLE_CODEX_STAGING_ENTRY=""
_MOLE_CLEAN_GUARD_REASON=""

_codex_staging_entry_is_still_stale() {
    local staging_root="$_MOLE_CODEX_STAGING_ROOT"
    local stale_entry="$_MOLE_CODEX_STAGING_ENTRY"
    [[ -n "$staging_root" && -n "$stale_entry" ]] || return 1
    [[ "${stale_entry%/*}" == "$staging_root" ]] || return 1
    [[ -d "$stale_entry" && ! -L "$stale_entry" ]] || return 1

    local physical_before=""
    local physical_after=""
    physical_before=$(codex_sparkle_staging_physical_path "$stale_entry") || return 1

    # The boundary must re-verify the same evidence that made the entry
    # eligible. A version-superseded entry re-reads its staged build and
    # compares against the installed build captured at scan time; an
    # age-eligible entry re-checks its age. Mixing them would let a young
    # superseded entry be refused here, or an aged-out check authorize an
    # entry whose staged build was swapped after the scan.
    if [[ "${_MOLE_CODEX_STAGING_MODE:-age}" == "superseded" ]]; then
        local installed_build="${_MOLE_CODEX_INSTALLED_BUILD:-}"
        [[ "$installed_build" =~ ^[0-9]+$ ]] || return 1
        # The scan-time verdict rested on the installed set being unique and
        # at this build. Re-resolve at the boundary: a copy installed or
        # swapped since the scan (say an older one whose pending update is
        # exactly this staged build) must void the supersession, not ride
        # a stale snapshot into a deletion.
        local installed_now=""
        installed_now=$(_codex_installed_build_version) || return 1
        [[ "$installed_now" == "$installed_build" ]] || return 1
        local staged_build=""
        staged_build=$(_codex_staged_build_version "$stale_entry") || return 1
        [[ "$staged_build" -le "$installed_build" ]] || return 1
        physical_after=$(codex_sparkle_staging_physical_path "$stale_entry") || return 1
        [[ "$physical_after" == "$physical_before" ]] || return 1
        return 0
    fi

    local stale_match=""
    while IFS= read -r -d '' stale_match; do
        physical_after=$(codex_sparkle_staging_physical_path "$stale_entry") || return 1
        [[ "$physical_after" == "$physical_before" ]] || return 1
        return 0
    done < <(command find -P "$stale_entry" -maxdepth 0 -type d -mtime +"$MOLE_ORPHAN_AGE_DAYS" -print0 2> /dev/null)
    return 1
}

_codex_staging_delete_guard_allows() {
    _MOLE_CLEAN_GUARD_REASON="staging entry changed"
    _codex_staging_entry_is_still_stale || return 1

    mole_clean_process_guard codex_desktop_process_state "Codex started" || return 1

    mole_clean_process_guard codex_sparkle_updater_running "Sparkle updater started" "updater state unknown" || return 1

    local open_file_state=0
    if codex_sparkle_staging_has_open_files "$_MOLE_CODEX_STAGING_ROOT"; then
        _MOLE_CLEAN_GUARD_REASON="staging files opened"
        return 1
    else
        open_file_state=$?
    fi
    if [[ $open_file_state -eq 124 || $open_file_state -ge 128 ]]; then
        _mole_record_clean_cancellation "$open_file_state"
        _MOLE_CLEAN_GUARD_REASON="open-file check unavailable"
        return 1
    fi
    if [[ $open_file_state -eq 2 ]]; then
        _MOLE_CLEAN_GUARD_REASON="open-file check unavailable"
        return 1
    fi

    # Process and open-file probes add another race window after the first path
    # check. Bind the same physical first-level entry and age again immediately
    # before safe_clean reaches its deletion sink.
    _codex_staging_entry_is_still_stale || return 1

    return 0
}

_codex_staging_safe_clean_guarded() {
    local staging_root="$1"
    local stale_entry="$2"
    _MOLE_CODEX_STAGING_ROOT="$staging_root"
    _MOLE_CODEX_STAGING_ENTRY="$stale_entry"
    _MOLE_CODEX_STAGING_MODE="${3:-age}"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! _codex_staging_delete_guard_allows; then
            return 75
        fi
        safe_clean "$stale_entry" "Codex Desktop stale update staging"
        return $?
    fi

    safe_clean_guarded \
        _codex_staging_delete_guard_allows \
        "$stale_entry" \
        "Codex Desktop stale update staging"
}

# Installed Codex Desktop build number, or failure. Two sources, per the
# single-probe rule: the fixed install paths first, a bounded mdfind second,
# both verified against the exact bundle id, and a strict bounded-decimal
# gate so prose or error text can never win a version comparison.
# Build number of one verified Codex install, or failure. Identity and
# version both come from the same plist, both gated.
_codex_app_build_version() {
    local candidate="$1"
    [[ -d "$candidate" ]] || return 1
    local cand_id=""
    cand_id=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$candidate/Contents/Info.plist" 2> /dev/null) || return 1
    [[ "$cand_id" == "com.openai.codex" ]] || return 1
    local build=""
    build=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
        "$candidate/Contents/Info.plist" 2> /dev/null) || return 1
    [[ "$build" =~ ^[0-9]+$ && ${#build} -le 10 ]] || return 1
    # Normalize to base 10 before anyone compares these. `[[ a -le b ]]` reads a
    # leading zero as octal, so a CFBundleVersion of 0123 would rank below 100
    # and a newer staged build could be called superseded; 08 and 09 are not
    # even valid octal and abort the test with a bash error on stderr.
    printf '%s\n' "$((10#$build))"
}

_codex_installed_build_version() {
    # All copies share one bundle id and therefore one staging cache, so a
    # staged build can belong to any of them. Supersession is only provable
    # against a UNIQUE installed version: two copies disagreeing on their
    # build make ownership ambiguous, and the caller falls back to the age
    # rule rather than deleting what may be the other copy's pending update.
    local resolved_build="" candidate build
    for candidate in "/Applications/Codex.app" "$HOME/Applications/Codex.app"; do
        build=$(_codex_app_build_version "$candidate") || continue
        if [[ -n "$resolved_build" && "$resolved_build" != "$build" ]]; then
            return 1
        fi
        resolved_build="$build"
    done
    # A failed or timed-out mdfind is an unanswered question, not an empty
    # answer: an unindexed extra copy elsewhere could be the owner of a
    # staged build we are about to call superseded. Fail the resolution and
    # let the caller fall back to the age rule; only a clean rc 0 with no
    # rows may mean "no other copies".
    local mdfind_out="" line
    mdfind_out=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" mdfind \
        "kMDItemCFBundleIdentifier == 'com.openai.codex'" 2> /dev/null) || return 1
    while IFS= read -r line; do
        [[ -d "$line" && "$line" == *.app ]] || continue
        case "$line" in
            "/Applications/Codex.app" | "$HOME/Applications/Codex.app") continue ;;
            "$HOME/Library/Caches/"*) continue ;;
        esac
        build=$(_codex_app_build_version "$line") || continue
        if [[ -n "$resolved_build" && "$resolved_build" != "$build" ]]; then
            return 1
        fi
        resolved_build="$build"
    done <<< "$mdfind_out"
    [[ -n "$resolved_build" ]] || return 1
    printf '%s\n' "$resolved_build"
}

# Build number of the app staged inside one first-level Installation entry.
# Only immediate .app children count, and two children disagreeing on the
# version is ambiguous and fails, so the caller falls back to the age rule.
_codex_staged_build_version() {
    local entry="$1"
    local staged_build="" staged_app build
    for staged_app in "$entry"/*.app; do
        [[ -d "$staged_app" ]] || continue
        # The staged app must prove the same identity as the installed one:
        # a version comparison across two different apps authorizes nothing,
        # and _codex_app_build_version gates id and version from one plist.
        build=$(_codex_app_build_version "$staged_app") || return 1
        if [[ -n "$staged_build" && "$staged_build" != "$build" ]]; then
            return 1
        fi
        staged_build="$build"
    done
    [[ -n "$staged_build" ]] || return 1
    printf '%s\n' "$staged_build"
}

clean_codex_desktop_staging() {
    local staging_root="$HOME/Library/Caches/com.openai.codex/org.sparkle-project.Sparkle/Installation"
    [[ -d "$staging_root" ]] || return 0
    if ! codex_sparkle_staging_physical_path "$staging_root" > /dev/null; then
        debug_log "Codex Desktop staging skipped: unsafe staging root"
        return 0
    fi

    # Version-aware eligibility (#1359): a staged build at or below the
    # installed one is superseded and removable at any age, a staged build
    # above it is a pending update and kept at any age, and an entry whose
    # versions cannot be read exactly keeps the original age-only rule.
    # Every guard between here and deletion is unchanged.
    local installed_build=""
    installed_build=$(_codex_installed_build_version) || installed_build=""
    _MOLE_CODEX_INSTALLED_BUILD="$installed_build"

    local -a stale_entries=()
    local -a stale_entry_modes=()
    local stale_entry
    while IFS= read -r -d '' stale_entry; do
        if ! codex_sparkle_staging_physical_path "$stale_entry" > /dev/null; then
            continue
        fi
        if ! mole_cleanup_targets_exist "$stale_entry"; then
            continue
        fi
        local staged_build=""
        if [[ -n "$installed_build" ]]; then
            staged_build=$(_codex_staged_build_version "$stale_entry") || staged_build=""
        fi
        if [[ -n "$installed_build" && -n "$staged_build" ]]; then
            if [[ "$staged_build" -le "$installed_build" ]]; then
                stale_entries+=("$stale_entry")
                stale_entry_modes+=("superseded")
            fi
            continue
        fi
        if [[ -n "$(command find -P "$stale_entry" -maxdepth 0 -type d \
            -mtime +"$MOLE_ORPHAN_AGE_DAYS" 2> /dev/null)" ]]; then
            stale_entries+=("$stale_entry")
            stale_entry_modes+=("age")
        fi
    done < <(command find -P "$staging_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)
    [[ ${#stale_entries[@]} -gt 0 ]] || return 0

    if is_path_whitelisted "$staging_root"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Codex Desktop update staging · would skip (whitelist)"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Codex Desktop update staging · skipped (whitelist)"
        fi
        note_activity
        return 0
    fi

    local process_state=0
    codex_desktop_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex Desktop update staging · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi

    local updater_state=0
    codex_sparkle_updater_running || updater_state=$?
    if [[ $updater_state -ne 1 ]]; then
        if [[ $updater_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex Desktop update staging · skipped (updater state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi

    local open_file_state=0
    if codex_sparkle_staging_has_open_files "$staging_root"; then
        mole_defer_cleanup_family "Codex"
        return 0
    else
        open_file_state=$?
    fi
    if [[ $open_file_state -eq 124 || $open_file_state -ge 128 ]]; then
        _mole_record_clean_cancellation "$open_file_state"
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex Desktop update staging · skipped (open-file check unavailable)"
        note_activity
        return 0
    fi
    if [[ "$open_file_state" -eq 2 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex Desktop update staging · skipped (open-file check unavailable)"
        note_activity
        return 0
    fi

    local stale_entry_idx=0
    for stale_entry in "${stale_entries[@]}"; do
        local guarded_rc=0
        _codex_staging_safe_clean_guarded "$staging_root" "$stale_entry" \
            "${stale_entry_modes[$stale_entry_idx]}" || guarded_rc=$?
        stale_entry_idx=$((stale_entry_idx + 1))
        if [[ $guarded_rc -eq 75 ]]; then
            case "$_MOLE_CLEAN_GUARD_REASON" in
                "process state unknown" | "updater state unknown" | "open-file check unavailable")
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex Desktop update staging · stopped (${_MOLE_CLEAN_GUARD_REASON})"
                    note_activity
                    ;;
                "staging entry changed")
                    debug_log "Codex Desktop staging entry changed before cleanup: $stale_entry"
                    ;;
                *) mole_defer_cleanup_family "Codex" ;;
            esac
            return 0
        fi
    done
}

# --- Codex Crashpad pending crash reports (#1490) -----------------------------
# Crash reports parked in Crashpad's pending queue are disposable diagnostics,
# and a wedged uploader can grow the queue pathologically (measured on a real
# install: 623,385 files, ~50 GiB). Candidates are stale DIRECT regular-file
# children of the exact pending directory only; the queue directory itself and
# every Crashpad sibling (new, completed, attachments, settings.dat) keep the
# blanket Application Support/Codex protection, and should_protect_path carves
# out exactly this one level and nothing deeper.

# Crashpad handlers name their database on the command line, so one argument
# probe covers the helper regardless of its binary name or a future app rename.
codex_crashpad_handler_process_state() {
    command -v pgrep > /dev/null 2>&1 || return 2
    local probe_status=0
    pgrep -f "Application Support/Codex/Crashpad" > /dev/null 2>&1 || probe_status=$?
    [[ $probe_status -eq 0 ]] && return 0
    [[ $probe_status -eq 1 ]] && return 1
    return 2
}

clean_codex_crashpad_pending() {
    local pending_root="$HOME/Library/Application Support/Codex/Crashpad/pending"
    [[ -d "$pending_root" ]] || return 0

    local physical_root=""
    if ! physical_root=$(codex_staging_physical_path "$pending_root" "$pending_root"); then
        debug_log "Codex Crashpad pending skipped: unsafe pending root"
        return 0
    fi

    # Age-bounded by design: a report Crashpad has not uploaded within the
    # orphan window is a stale backlog entry, while younger reports may still
    # be queued for a genuine upload and stay.
    local first_candidate=""
    first_candidate=$(command find -P "$physical_root" -mindepth 1 -maxdepth 1 -type f \
        -mtime +"$MOLE_ORPHAN_AGE_DAYS" -print 2> /dev/null | head -1) || true
    [[ -n "$first_candidate" ]] || return 0

    local display_name="Codex crash reports"
    local process_state=0
    codex_desktop_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi
    local handler_state=0
    codex_crashpad_handler_process_state || handler_state=$?
    if [[ $handler_state -ne 1 ]]; then
        if [[ $handler_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (crash handler state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi

    # One open-file probe over the queue before the loop: lsof +D walks the
    # whole tree, so a per-file probe on a six-figure backlog would multiply a
    # minutes-long scan. Path facts are re-bound per file below, and the
    # process question is re-asked periodically inside the loop.
    local open_file_state=0
    if codex_sparkle_staging_has_open_files "$physical_root"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (reports in use)"
        note_activity
        return 0
    else
        open_file_state=$?
    fi
    if [[ $open_file_state -eq 124 || $open_file_state -ge 128 ]]; then
        _mole_record_clean_cancellation "$open_file_state"
        return "$open_file_state"
    fi
    if [[ $open_file_state -eq 2 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} ${display_name} · skipped (open-file check unavailable)"
        note_activity
        return 0
    fi

    local dry_run_mode=false
    [[ "${DRY_RUN:-false}" == "true" || "${MOLE_DRY_RUN:-0}" == "1" ]] && dry_run_mode=true

    local count=0 cleaned_kb=0 file_path file_size_kb size_rc remove_rc
    local guard_interval=1000 since_guard=0
    while IFS= read -r -d '' file_path; do
        # Re-bind the path facts at the sink: still a direct child of the
        # physical root, still a regular file, never a symlink.
        [[ "${file_path%/*}" == "$physical_root" ]] || continue
        [[ -f "$file_path" && ! -L "$file_path" ]] || continue

        if [[ $since_guard -ge $guard_interval ]]; then
            since_guard=0
            if ! mole_clean_process_guard codex_desktop_process_state "Codex started" ||
                ! mole_clean_process_guard codex_crashpad_handler_process_state "crash handler started"; then
                mole_report_guard_stop "$display_name" mole_defer_cleanup_family "Codex"
                break
            fi
        fi
        since_guard=$((since_guard + 1))

        size_rc=0
        file_size_kb=$(get_path_size_kb "$file_path") || size_rc=$?
        if [[ $size_rc -ne 0 ]]; then
            if [[ $size_rc -lt 128 ]]; then
                debug_log "Codex crash report sizing failed (rc=$size_rc), skipping: $file_path"
                continue
            fi
            _mole_record_clean_cancellation "$size_rc"
            return "$size_rc"
        fi
        remove_rc=1
        if [[ "$dry_run_mode" == "true" ]]; then
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$file_path" "$file_size_kb" 1 true || continue
            fi
            MOLE_DRY_RUN=1 safe_remove "$file_path" true "$file_size_kb" && remove_rc=0
        elif safe_remove "$file_path" true "$file_size_kb"; then
            remove_rc=0
        fi
        if [[ $remove_rc -eq 0 ]]; then
            count=$((count + 1))
            cleaned_kb=$((cleaned_kb + file_size_kb))
        fi
    done < <(command find -P "$physical_root" -mindepth 1 -maxdepth 1 -type f \
        -mtime +"$MOLE_ORPHAN_AGE_DAYS" -print0 2> /dev/null || true)

    if [[ $count -gt 0 ]]; then
        local cleaned_mb
        cleaned_mb=$(echo "$cleaned_kb" | awk '{printf "%.1f", $1/1024}' || echo "0.0")
        if [[ "$dry_run_mode" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Would clean $count stale Codex crash reports older than ${MOLE_ORPHAN_AGE_DAYS}d, about ${cleaned_mb}MB"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $count stale Codex crash reports older than ${MOLE_ORPHAN_AGE_DAYS}d, about ${cleaned_mb}MB"
        fi
        note_activity
    fi
}

antigravity_or_gemini_running() {
    mole_pgrep_any \
        -x "Antigravity" \
        -f "/Antigravity.app/" \
        -x "gemini" \
        -f "antigravity-browser-profile"
}

chrome_devtools_mcp_running() {
    mole_pgrep_any -f "chrome-devtools-mcp"
}

is_codex_runtime_active() {
    local runtime_dir="$1"
    [[ -d "$runtime_dir" ]] || return 1
    [[ -f "$runtime_dir/runtime.json" ]] || return 1
    [[ -d "$runtime_dir/dependencies/node" || -d "$runtime_dir/dependencies/python" ]] || return 1
    return 0
}

is_codex_runtime_stale() {
    local runtime_dir="$1"
    [[ -d "$runtime_dir" ]] || return 1

    local runtime_name
    runtime_name="$(basename "$runtime_dir")"
    case "$runtime_name" in
        tmp* | temp* | *.tmp | incomplete* | *.incomplete | *-incomplete | partial* | *.partial)
            return 0
            ;;
    esac

    if [[ ! -e "$runtime_dir/runtime.json" && ! -e "$runtime_dir/dependencies" ]]; then
        return 0
    fi

    return 1
}

_codex_runtime_size_human() {
    local target="$1"
    local output_var="$2"
    local size_kb=0

    if declare -f get_path_size_kb > /dev/null 2>&1; then
        local size_rc=0
        size_kb=$(get_path_size_kb "$target" 2> /dev/null) || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
    fi

    local formatted_size
    if declare -f bytes_to_human > /dev/null 2>&1; then
        formatted_size=$(bytes_to_human "$((size_kb * 1024))")
    else
        formatted_size="${size_kb} KB"
    fi
    printf -v "$output_var" '%s' "$formatted_size"
}

_codex_runtime_delete_guard_allows() {
    mole_clean_process_guard codex_runtime_process_state "Codex started" || return 1

    if is_codex_runtime_active "$_MOLE_CODEX_RUNTIME_GUARD_PATH" ||
        ! is_codex_runtime_stale "$_MOLE_CODEX_RUNTIME_GUARD_PATH"; then
        _MOLE_CLEAN_GUARD_REASON="runtime state changed"
        return 1
    fi
    return 0
}

_codex_runtime_safe_clean_guarded() {
    local runtime_dir="$1"
    local _MOLE_CODEX_RUNTIME_GUARD_PATH="$runtime_dir"
    local _MOLE_CLEAN_GUARD_REASON="Codex started"
    local guarded_rc=0

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! _codex_runtime_delete_guard_allows; then
            guarded_rc=75
        else
            safe_clean "$runtime_dir" "Codex CLI runtimes"
            return $?
        fi
    else
        safe_clean_guarded \
            _codex_runtime_delete_guard_allows \
            "$runtime_dir" \
            "Codex CLI runtimes" || guarded_rc=$?
    fi

    if [[ $guarded_rc -eq 75 ]]; then
        if [[ "$_MOLE_CLEAN_GUARD_REASON" == "Codex started" ]]; then
            mole_defer_cleanup_family "Codex"
        else
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex runtimes · stopped (${_MOLE_CLEAN_GUARD_REASON})"
            note_activity
        fi
        return 1
    fi
    return "$guarded_rc"
}

clean_codex_runtimes() {
    local runtime_root="$HOME/.cache/codex-runtimes"
    [[ -d "$runtime_root" ]] || return 0

    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$runtime_root"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Codex runtimes · would skip (whitelist)"
            note_activity
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Codex runtimes · skipped (whitelist)"
        fi
        note_activity
        return 0
    fi

    local has_stale_runtime=false
    local runtime_dir
    while IFS= read -r -d '' runtime_dir; do
        if ! is_codex_runtime_active "$runtime_dir" &&
            is_codex_runtime_stale "$runtime_dir" &&
            mole_cleanup_targets_exist "$runtime_dir"; then
            has_stale_runtime=true
            break
        fi
    done < <(command find "$runtime_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)

    local process_state=0
    codex_runtime_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ "$has_stale_runtime" != "true" ]]; then
            return 0
        elif [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex runtimes · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi

    local size_human=""
    _codex_runtime_size_human "$runtime_root" size_human || return $?
    echo -e "  ${GRAY}${ICON_REVIEW}${NC} Codex runtimes · manual review (${size_human})"
    note_activity

    while IFS= read -r -d '' runtime_dir; do
        if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$runtime_dir"; then
            if [[ "${DRY_RUN:-false}" == "true" ]]; then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Codex runtimes · would skip (whitelist)"
                note_activity
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Codex runtimes · skipped (whitelist)"
            fi
            note_activity
            continue
        fi

        if is_codex_runtime_active "$runtime_dir"; then
            debug_log "Codex runtime left for manual review: $runtime_dir"
            continue
        fi

        if is_codex_runtime_stale "$runtime_dir"; then
            _codex_runtime_safe_clean_guarded "$runtime_dir" || return 0
        else
            debug_log "Codex runtime left for manual review: $runtime_dir"
        fi
    done < <(command find "$runtime_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)
}

# Codex CLI and Desktop share state under ~/.codex. Keep it out of default
# cleanup so app indexes, sessions, credentials, and local thread state survive.
clean_codex_cli() {
    local codex_root="$HOME/.codex"
    [[ -d "$codex_root" ]] || return 0

    debug_log "Codex CLI state left intact by default: $codex_root"
}

_MOLE_CODEX_MARKETPLACE_STAGING_ROOT=""
_MOLE_CODEX_MARKETPLACE_STAGING_ENTRY=""

_codex_marketplace_staging_entry_is_still_stale() {
    local staging_root="$_MOLE_CODEX_MARKETPLACE_STAGING_ROOT"
    local stale_entry="$_MOLE_CODEX_MARKETPLACE_STAGING_ENTRY"
    [[ -n "$staging_root" && -n "$stale_entry" ]] || return 1
    [[ "${stale_entry%/*}" == "$staging_root" ]] || return 1
    [[ -d "$stale_entry" && ! -L "$stale_entry" ]] || return 1

    local physical_before=""
    local physical_after=""
    physical_before=$(codex_staging_physical_path "$stale_entry" "$staging_root") || return 1

    if [[ -z "$(command find -P "$stale_entry" -maxdepth 0 -type d \
        -mtime +"$MOLE_ORPHAN_AGE_DAYS" 2> /dev/null)" ]]; then
        return 1
    fi

    physical_after=$(codex_staging_physical_path "$stale_entry" "$staging_root") || return 1
    [[ "$physical_before" == "$physical_after" ]] || return 1
    return 0
}

_codex_marketplace_staging_delete_guard_allows() {
    _codex_marketplace_staging_entry_is_still_stale || return 1
    mole_clean_process_guard codex_runtime_process_state "Codex started" || return 1
    if codex_sparkle_staging_has_open_files "$_MOLE_CODEX_MARKETPLACE_STAGING_ROOT"; then
        _MOLE_CLEAN_GUARD_REASON="open files"
        return 1
    else
        local open_file_state=$?
        if [[ "$open_file_state" -eq 124 || "$open_file_state" -ge 128 ]]; then
            _mole_record_clean_cancellation "$open_file_state"
            _MOLE_CLEAN_GUARD_REASON="open-file check unavailable"
            return 1
        fi
        if [[ "$open_file_state" -eq 2 ]]; then
            _MOLE_CLEAN_GUARD_REASON="open-file check unavailable"
            return 1
        fi
    fi
    _codex_marketplace_staging_entry_is_still_stale || return 1
    return 0
}

_codex_marketplace_staging_safe_clean_guarded() {
    local staging_root="$1"
    local stale_entry="$2"
    local display_name="$3"
    _MOLE_CODEX_MARKETPLACE_STAGING_ROOT="$staging_root"
    _MOLE_CODEX_MARKETPLACE_STAGING_ENTRY="$stale_entry"
    local _MOLE_CLEAN_GUARD_REASON="staging entry changed"

    # No engine-absent fallback here on purpose: a second, degraded copy of the
    # delete guard is a place the guarded and unguarded verdicts can disagree,
    # and the audit in `tests/clean_core.bats` caps how many of those exist.
    # Standalone callers provide `safe_clean_guarded` instead.
    local guarded_rc=0
    safe_clean_guarded _codex_marketplace_staging_delete_guard_allows \
        "$stale_entry" "$display_name" || guarded_rc=$?
    return "$guarded_rc"
}

# Abandoned Codex marketplace staging leftovers (#1389). Completes marketplaces
# such as openai-bundled and configured marketplace dirs are never candidates;
# only exact staging prefixes under fixed roots, aged by MOLE_ORPHAN_AGE_DAYS.
# marketplace-backup-* stays out of scope until recovery semantics are clear.
clean_codex_marketplace_staging() {
    local tmp_root="$HOME/.codex/.tmp"
    [[ -d "$tmp_root" ]] || return 0

    local -a staging_roots=(
        "$tmp_root/bundled-marketplaces"
        "$tmp_root/marketplaces/.staging"
    )
    local -a staging_prefixes=(
        "openai-bundled.staging-"
        "marketplace-upgrade-"
        "marketplace-add-"
    )

    local -a stale_entries=()
    local -a stale_roots=()
    local staging_root prefix stale_entry
    for staging_root in "${staging_roots[@]}"; do
        [[ -d "$staging_root" ]] || continue
        if ! codex_staging_physical_path "$staging_root" "$staging_root" > /dev/null; then
            debug_log "Codex marketplace staging skipped: unsafe root $staging_root"
            continue
        fi
        while IFS= read -r -d '' stale_entry; do
            local base
            base=$(basename "$stale_entry")
            local matched=false
            for prefix in "${staging_prefixes[@]}"; do
                case "$base" in
                    "$prefix"*)
                        matched=true
                        break
                        ;;
                esac
            done
            [[ "$matched" == "true" ]] || continue
            if ! codex_staging_physical_path "$stale_entry" "$staging_root" > /dev/null; then
                continue
            fi
            if ! mole_cleanup_targets_exist "$stale_entry"; then
                continue
            fi
            if [[ -n "$(command find -P "$stale_entry" -maxdepth 0 -type d \
                -mtime +"$MOLE_ORPHAN_AGE_DAYS" 2> /dev/null)" ]]; then
                stale_entries+=("$stale_entry")
                stale_roots+=("$staging_root")
            fi
        done < <(command find -P "$staging_root" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null)
    done
    [[ ${#stale_entries[@]} -gt 0 ]] || return 0

    if is_path_whitelisted "$tmp_root" || is_path_whitelisted "$HOME/.codex"; then
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Codex marketplace staging · would skip (whitelist)"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Codex marketplace staging · skipped (whitelist)"
        fi
        note_activity
        return 0
    fi

    local process_state=0
    codex_runtime_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex marketplace staging · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Codex"
        fi
        return 0
    fi

    local open_file_state=0
    # Reuse the Sparkle open-file helper shape against each staging root only
    # when that root still has candidates (open files on an idle sibling root
    # must not block cleanup elsewhere).
    local idx=0
    for stale_entry in "${stale_entries[@]}"; do
        staging_root="${stale_roots[$idx]}"
        idx=$((idx + 1))

        if is_path_whitelisted "$stale_entry"; then
            continue
        fi

        open_file_state=0
        if codex_sparkle_staging_has_open_files "$staging_root"; then
            mole_defer_cleanup_family "Codex"
            return 0
        else
            open_file_state=$?
        fi
        if [[ "$open_file_state" -eq 124 || "$open_file_state" -ge 128 ]]; then
            _mole_record_clean_cancellation "$open_file_state"
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex marketplace staging · skipped (open-file check unavailable)"
            note_activity
            return 0
        fi
        if [[ "$open_file_state" -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex marketplace staging · skipped (open-file check unavailable)"
            note_activity
            return 0
        fi

        local guarded_rc=0
        _codex_marketplace_staging_safe_clean_guarded \
            "$staging_root" "$stale_entry" \
            "Codex marketplace staging" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            case "${_MOLE_CLEAN_GUARD_REASON:-}" in
                "process state unknown" | "open-file check unavailable")
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex marketplace staging · stopped (${_MOLE_CLEAN_GUARD_REASON})"
                    note_activity
                    ;;
                "staging entry changed")
                    debug_log "Codex marketplace staging entry changed before cleanup: $stale_entry"
                    ;;
                *) mole_defer_cleanup_family "Codex" ;;
            esac
            return 0
        fi
    done
}

# Shared Chromium Default profile caches that are safe to regenerate.
clean_chromium_default_caches() {
    local profile_root="$1"
    local label="$2"
    local running_probe="${3:-}"
    local family="${4:-$label}"

    [[ -d "$profile_root" ]] || return 0

    if [[ -z "$running_probe" ]]; then
        safe_clean "$profile_root/Default/Cache"/* "$label browser cache"
        safe_clean "$profile_root/Default/Code Cache"/* "$label code cache"
        safe_clean "$profile_root/Default/GPUCache"/* "$label GPU cache"
        safe_clean "$profile_root/Default/DawnGraphiteCache"/* "$label Dawn cache"
        safe_clean "$profile_root/Default/DawnWebGPUCache"/* "$label WebGPU cache"
        return 0
    fi

    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label browser cache" \
        "$profile_root/Default/Cache"/* "$label browser cache" || return 1
    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label code cache" \
        "$profile_root/Default/Code Cache"/* "$label code cache" || return 1
    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label GPU cache" \
        "$profile_root/Default/GPUCache"/* "$label GPU cache" || return 1
    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label Dawn cache" \
        "$profile_root/Default/DawnGraphiteCache"/* "$label Dawn cache" || return 1
    _dev_safe_clean_process_guarded "$running_probe" "$family" "$label WebGPU cache" \
        "$profile_root/Default/DawnWebGPUCache"/* "$label WebGPU cache" || return 1
}

# Antigravity (Gemini) keeps a full Chromium profile under
# ~/.gemini/antigravity-browser-profile. Clean its regenerable browser
# caches, mirroring the Antigravity Electron cache cleanup in clean_dev_misc.
clean_antigravity_caches() {
    local ag_profile="$HOME/.gemini/antigravity-browser-profile"
    [[ -d "$ag_profile" ]] || return 0

    mole_cleanup_targets_exist \
        "$ag_profile/Default/Cache"/* \
        "$ag_profile/Default/Code Cache"/* \
        "$ag_profile/Default/GPUCache"/* \
        "$ag_profile/Default/DawnGraphiteCache"/* \
        "$ag_profile/Default/DawnWebGPUCache"/* \
        "$ag_profile/GraphiteDawnCache"/* \
        "$ag_profile/component_crx_cache"/* \
        "$ag_profile/extensions_crx_cache"/* \
        "$ag_profile/Default/Service Worker/CacheStorage"/* || return 0

    local process_state=0
    antigravity_or_gemini_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Antigravity/Gemini caches · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Antigravity/Gemini"
        fi
        return 0
    fi

    clean_chromium_default_caches \
        "$ag_profile" \
        "Antigravity" \
        antigravity_or_gemini_running \
        "Antigravity/Gemini" || return 0
    _dev_safe_clean_process_guarded antigravity_or_gemini_running "Antigravity/Gemini" \
        "Antigravity Graphite cache" "$ag_profile/GraphiteDawnCache"/* "Antigravity Graphite cache" || return 0
    _dev_safe_clean_process_guarded antigravity_or_gemini_running "Antigravity/Gemini" \
        "Antigravity component cache" "$ag_profile/component_crx_cache"/* "Antigravity component cache" || return 0
    _dev_safe_clean_process_guarded antigravity_or_gemini_running "Antigravity/Gemini" \
        "Antigravity extension cache" "$ag_profile/extensions_crx_cache"/* "Antigravity extension cache" || return 0
    _dev_clean_service_worker_process_guarded \
        antigravity_or_gemini_running \
        "Antigravity/Gemini" \
        "Antigravity Service Worker" \
        "Antigravity" \
        "$ag_profile/Default/Service Worker/CacheStorage" || return 0
    # Never clean ~/.gemini/tmp: despite the name it stores gemini-cli
    # conversation checkpoints and prompt history (AI chat state, not temp).
}

clean_chrome_devtools_mcp_caches() {
    local mcp_profile="$HOME/.cache/chrome-devtools-mcp/chrome-profile"
    [[ -d "$mcp_profile" ]] || return 0

    mole_cleanup_targets_exist \
        "$mcp_profile/Default/Cache"/* \
        "$mcp_profile/Default/Code Cache"/* \
        "$mcp_profile/Default/GPUCache"/* \
        "$mcp_profile/Default/DawnGraphiteCache"/* \
        "$mcp_profile/Default/DawnWebGPUCache"/* \
        "$mcp_profile/Default/DawnCache"/* \
        "$mcp_profile/Default/GrShaderCache"/* \
        "$mcp_profile/Default/GraphiteDawnCache"/* \
        "$mcp_profile/GraphiteDawnCache"/* \
        "$mcp_profile/component_crx_cache"/* \
        "$mcp_profile/extensions_crx_cache"/* \
        "$mcp_profile/Default/Service Worker/CacheStorage"/* || return 0

    local process_state=0
    chrome_devtools_mcp_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Chrome DevTools MCP caches · skipped (process state unknown)"
            note_activity
        else
            mole_defer_cleanup_family "Chrome DevTools MCP"
        fi
        return 0
    fi

    clean_chromium_default_caches \
        "$mcp_profile" \
        "Chrome DevTools MCP" \
        chrome_devtools_mcp_running \
        "Chrome DevTools MCP" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP Dawn cache" "$mcp_profile/Default/DawnCache"/* "Chrome DevTools MCP Dawn cache" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP shader cache" "$mcp_profile/Default/GrShaderCache"/* "Chrome DevTools MCP shader cache" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP Graphite cache" "$mcp_profile/Default/GraphiteDawnCache"/* \
        "$mcp_profile/GraphiteDawnCache"/* "Chrome DevTools MCP Graphite cache" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP component cache" "$mcp_profile/component_crx_cache"/* "Chrome DevTools MCP component cache" || return 0
    _dev_safe_clean_process_guarded chrome_devtools_mcp_running "Chrome DevTools MCP" \
        "Chrome DevTools MCP extension cache" "$mcp_profile/extensions_crx_cache"/* "Chrome DevTools MCP extension cache" || return 0

    if declare -f clean_service_worker_cache > /dev/null 2>&1; then
        _dev_clean_service_worker_process_guarded \
            chrome_devtools_mcp_running \
            "Chrome DevTools MCP" \
            "Chrome DevTools MCP Service Worker" \
            "Chrome DevTools MCP" \
            "$mcp_profile/Default/Service Worker/CacheStorage" || return 0
    fi
}

# Misc dev tool caches.
clean_dev_misc() {
    safe_clean ~/Library/Caches/com.unity3d.*/* "Unity cache"
    safe_clean ~/Library/Caches/com.mongodb.compass/* "MongoDB Compass cache"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Figma cache"
    safe_clean ~/Library/Caches/com.github.GitHubDesktop/* "GitHub Desktop cache"
    safe_clean ~/Library/Caches/SentryCrash/* "Sentry crash reports"
    safe_clean ~/Library/Caches/KSCrash/* "KSCrash reports"
    safe_clean ~/Library/Caches/com.crashlytics.data/* "Crashlytics data"
    if [[ -d ~/Library/Application\ Support/Antigravity ]]; then
        safe_clean ~/Library/Application\ Support/Antigravity/Cache/* "Antigravity cache"
        safe_clean ~/Library/Application\ Support/Antigravity/Code\ Cache/* "Antigravity code cache"
        safe_clean ~/Library/Application\ Support/Antigravity/GPUCache/* "Antigravity GPU cache"
        safe_clean ~/Library/Application\ Support/Antigravity/DawnGraphiteCache/* "Antigravity Dawn cache"
        safe_clean ~/Library/Application\ Support/Antigravity/DawnWebGPUCache/* "Antigravity WebGPU cache"
    fi
    # Antigravity browser profile caches (~/.gemini)
    clean_antigravity_caches
    # Filo (Electron)
    if [[ -d ~/Library/Application\ Support/Filo ]]; then
        safe_clean ~/Library/Application\ Support/Filo/production/Cache/* "Filo cache"
        safe_clean ~/Library/Application\ Support/Filo/production/Code\ Cache/* "Filo code cache"
        safe_clean ~/Library/Application\ Support/Filo/production/GPUCache/* "Filo GPU cache"
        safe_clean ~/Library/Application\ Support/Filo/production/DawnGraphiteCache/* "Filo Dawn cache"
        safe_clean ~/Library/Application\ Support/Filo/production/DawnWebGPUCache/* "Filo WebGPU cache"
    fi
    # Claude (Electron)
    if [[ -d ~/Library/Application\ Support/Claude ]]; then
        safe_clean ~/Library/Application\ Support/Claude/Cache/* "Claude cache"
        safe_clean ~/Library/Application\ Support/Claude/Code\ Cache/* "Claude code cache"
        safe_clean ~/Library/Application\ Support/Claude/GPUCache/* "Claude GPU cache"
        safe_clean ~/Library/Application\ Support/Claude/DawnGraphiteCache/* "Claude Dawn cache"
        safe_clean ~/Library/Application\ Support/Claude/DawnWebGPUCache/* "Claude WebGPU cache"
        safe_clean ~/Library/Application\ Support/Claude/sentry/* "Claude sentry cache"
    fi
    # Qoder (VS Code fork, Electron)
    if [[ -d ~/Library/Application\ Support/Qoder ]]; then
        safe_clean ~/Library/Application\ Support/Qoder/Cache/* "Qoder cache"
        safe_clean ~/Library/Application\ Support/Qoder/CachedData/* "Qoder cached data"
        safe_clean ~/Library/Application\ Support/Qoder/CachedExtensionVSIXs/* "Qoder extension cache"
        safe_clean ~/Library/Application\ Support/Qoder/Code\ Cache/* "Qoder code cache"
        safe_clean ~/Library/Application\ Support/Qoder/GPUCache/* "Qoder GPU cache"
        safe_clean ~/Library/Application\ Support/Qoder/DawnGraphiteCache/* "Qoder Dawn cache"
        safe_clean ~/Library/Application\ Support/Qoder/DawnWebGPUCache/* "Qoder WebGPU cache"
        safe_clean ~/Library/Application\ Support/Qoder/logs/* "Qoder logs"
    fi
    # Prisma ORM engine binaries cache
    safe_clean ~/.cache/prisma/* "Prisma cache"
    # OpenCode AI tool cache
    safe_clean ~/.cache/opencode/* "OpenCode cache"
    # OpenCode snapshots back restore/revert, while diagnostic JSONL logs can
    # contain prompts and transcript events. Neither is default-cleanable.
    # Codex Chromium runtime caches are separate from its protected Application
    # Support profile and are restricted to measured fixed leaves.
    clean_codex_desktop_caches
    # Codex Desktop runtimes contain active Node/Python dependencies.
    clean_codex_runtimes
    # Sparkle uses random first-level directories for each update installation.
    clean_codex_desktop_staging
    # Stale Crashpad pending crash reports (#1490); age, process, crash-handler,
    # and open-file gated, direct children of the pending queue only.
    clean_codex_crashpad_pending
    # Abandoned marketplace staging under ~/.codex/.tmp (completed marketplaces stay).
    clean_codex_marketplace_staging
    # Codex CLI working-directory caches (~/.codex)
    clean_codex_cli
    # Cursor Agent session logs (versions cleaned separately in clean_dev_ai_agents)
    [[ -d "$HOME/.local/share/cursor-agent" ]] && safe_find_delete "$HOME/.local/share/cursor-agent" "*.log" "$MOLE_LOG_AGE_DAYS" "f"
    # Playwright browser revisions are hard-protected by should_protect_path,
    # so no safe_clean call here can ever remove them. They cost a 100-500 MB
    # CDN re-download and a stale registry link does not prove the user is done
    # with the revision. Keep this surface read-only.
    # Chrome DevTools MCP keeps a Chromium profile; clean only rebuildable caches.
    clean_chrome_devtools_mcp_caches
    # Claude Code state under ~/.claude can include persistent memory,
    # plugin registry data, hooks, and session context. Do not clean it
    # automatically; users can remove specific paths manually if needed.
    # Wondershare orphan installer payload (bundle ID differs from live app)
    safe_clean ~/Library/Application\ Support/com.wondershare.Installer/* "Wondershare installer payload"
}
# Shell and VCS leftovers.
clean_dev_shell() {
    safe_clean ~/.gitconfig.lock "Git config lock"
    safe_clean ~/.gitconfig.bak* "Git config backup"
    safe_clean ~/.oh-my-zsh/cache/* "Oh My Zsh cache"
    safe_clean ~/.config/fish/fish_history.bak* "Fish shell backup"
    safe_clean ~/.bash_history.bak* "Bash history backup"
    safe_clean ~/.zsh_history.bak* "Zsh history backup"
    safe_clean ~/.cache/pre-commit/* "pre-commit cache"
}
# Network tool caches.
clean_dev_network() {
    safe_clean ~/.cache/curl/* "curl cache"
    safe_clean ~/.cache/wget/* "wget cache"
    safe_clean ~/Library/Caches/curl/* "macOS curl cache"
    safe_clean ~/Library/Caches/wget/* "macOS wget cache"
}
# Elixir/Erlang ecosystem.
# Note: ~/.mix/archives contains installed Mix tools - excluded from cleanup
clean_dev_elixir() {
    safe_clean ~/.hex/cache/* "Hex cache"
}
# Haskell has no cleanup stage: ~/.stack/programs holds Stack-installed GHC
# compilers and ~/.cabal/packages is the downloaded source-tarball store cabal
# resolves builds against, so both are toolchain or dependency state rather
# than a redundant copy Mole can drop.
# OCaml ecosystem.
clean_dev_ocaml() {
    safe_clean ~/.opam/download-cache/* "Opam cache"
}

_run_developer_cleanup_step() {
    local strict=false
    if [[ "${1:-}" == "--strict" ]]; then
        strict=true
        shift
    fi

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ $pending_clean_cancel -eq 124 || $pending_clean_cancel -ge 128 ]]; then
        return "$pending_clean_cancel"
    fi

    local step_name="${1:-developer cleanup step}"
    local _perf_step_start
    debug_timer_start _perf_step_start
    local step_rc=0
    "$@" || step_rc=$?
    debug_timer_end "developer cleanup step: $step_name" _perf_step_start
    if [[ $step_rc -eq 124 || $step_rc -ge 128 ]]; then
        _mole_record_clean_cancellation "$step_rc"
        return "$step_rc"
    fi

    pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ $pending_clean_cancel -eq 124 || $pending_clean_cancel -ge 128 ]]; then
        return "$pending_clean_cancel"
    fi
    [[ "$strict" == "true" && $step_rc -ne 0 ]] && return "$step_rc"
    return 0
}

# Main developer tools cleanup sequence.
clean_developer_tools() {
    stop_section_spinner

    # CLI tools and languages
    _run_developer_cleanup_step clean_dev_npm || return $?
    _run_developer_cleanup_step clean_dev_python || return $?
    _run_developer_cleanup_step clean_dev_go || return $?
    _run_developer_cleanup_step clean_dev_mise || return $?
    _run_developer_cleanup_step clean_dev_rust || return $?
    _run_developer_cleanup_step check_rust_toolchains || return $?
    _run_developer_cleanup_step clean_dev_ruby || return $?
    _run_developer_cleanup_step clean_dev_perl || return $?
    _run_developer_cleanup_step clean_dev_docker || return $?
    _run_developer_cleanup_step clean_dev_cloud || return $?
    _run_developer_cleanup_step clean_dev_nix || return $?
    _run_developer_cleanup_step clean_dev_shell || return $?
    _run_developer_cleanup_step clean_dev_frontend || return $?
    _run_developer_cleanup_step clean_project_caches || return $?
    _run_developer_cleanup_step --strict clean_dev_mobile || return $?
    _run_developer_cleanup_step clean_dev_jvm || return $?
    _run_developer_cleanup_step clean_dev_jetbrains_toolbox || return $?
    _run_developer_cleanup_step clean_dev_jetbrains_logs || return $?
    _run_developer_cleanup_step --strict clean_dev_ai_agents || return $?
    _run_developer_cleanup_step clean_dev_automation_browsers || return $?
    _run_developer_cleanup_step clean_dev_other_langs || return $?
    _run_developer_cleanup_step clean_dev_cicd || return $?
    _run_developer_cleanup_step clean_dev_database || return $?
    _run_developer_cleanup_step clean_dev_api_tools || return $?
    _run_developer_cleanup_step clean_dev_network || return $?
    _run_developer_cleanup_step clean_dev_misc || return $?
    _run_developer_cleanup_step clean_dev_elixir || return $?
    _run_developer_cleanup_step clean_dev_ocaml || return $?

    # GUI developer applications
    _run_developer_cleanup_step --strict clean_xcode_tools || return $?
    _run_developer_cleanup_step clean_code_editors || return $?

    # Homebrew: only blanket-clean downloads/. Wiping api/ (JSON that needs a
    # network re-download) and bootsnap/ (recompiled Ruby) leaves brew silent
    # for ~94s before its first output on the next run.
    _run_developer_cleanup_step \
        safe_clean ~/Library/Caches/Homebrew/downloads/* "Homebrew cache" || return $?
    local brew_lock_dirs=(
        "/opt/homebrew/var/homebrew/locks"
        "/usr/local/var/homebrew/locks"
    )
    for lock_dir in "${brew_lock_dirs[@]}"; do
        if [[ -d "$lock_dir" && -w "$lock_dir" ]]; then
            _run_developer_cleanup_step \
                safe_clean "$lock_dir"/* "Homebrew lock files" || return $?
        elif [[ -d "$lock_dir" ]]; then
            if find "$lock_dir" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
                debug_log "Skipping read-only Homebrew locks in $lock_dir"
            fi
        fi
    done
    _run_developer_cleanup_step clean_homebrew || return $?
}
