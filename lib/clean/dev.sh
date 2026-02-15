#!/bin/bash
# Developer Tools Cleanup Module
set -euo pipefail

# Tool cache helper (respects DRY_RUN).
clean_tool_cache() {
    local description="$1"
    shift
    if [[ "$DRY_RUN" != "true" ]]; then
        if "$@" > /dev/null 2>&1; then
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $description"
        fi
    else
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $description · would clean"
    fi
    return 0
}
# npm/pnpm/yarn/bun caches.
clean_dev_npm() {
    local npm_default_cache="$HOME/.npm"
    local npm_cache_path="$npm_default_cache"

    if command -v npm > /dev/null 2>&1; then
        clean_tool_cache "npm cache" npm cache clean --force

        start_section_spinner "Checking npm cache path..."
        npm_cache_path=$(run_with_timeout 2 npm config get cache 2> /dev/null) || npm_cache_path=""
        stop_section_spinner

        if [[ -z "$npm_cache_path" || "$npm_cache_path" != /* ]]; then
            npm_cache_path="$npm_default_cache"
        fi

        note_activity
    fi

    safe_clean "$npm_default_cache"/_cacache/* "npm cache directory"
    safe_clean "$npm_default_cache"/_npx/* "npm npx cache"
    safe_clean "$npm_default_cache"/_logs/* "npm logs"
    safe_clean "$npm_default_cache"/_prebuilds/* "npm prebuilds"

    if [[ "$npm_cache_path" != "$npm_default_cache" ]]; then
        safe_clean "$npm_cache_path"/_cacache/* "npm cache directory (custom path)"
        safe_clean "$npm_cache_path"/_npx/* "npm npx cache (custom path)"
        safe_clean "$npm_cache_path"/_logs/* "npm logs (custom path)"
        safe_clean "$npm_cache_path"/_prebuilds/* "npm prebuilds (custom path)"
    fi

    # Clean pnpm store cache
    local pnpm_default_store=~/Library/pnpm/store
    # Check if pnpm is actually usable (not just Corepack shim)
    if command -v pnpm > /dev/null 2>&1 && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm --version > /dev/null 2>&1; then
        COREPACK_ENABLE_DOWNLOAD_PROMPT=0 clean_tool_cache "pnpm cache" pnpm store prune
        local pnpm_store_path
        start_section_spinner "Checking store path..."
        pnpm_store_path=$(COREPACK_ENABLE_DOWNLOAD_PROMPT=0 run_with_timeout 2 pnpm store path 2> /dev/null) || pnpm_store_path=""
        stop_section_spinner
        if [[ -n "$pnpm_store_path" && "$pnpm_store_path" != "$pnpm_default_store" ]]; then
            safe_clean "$pnpm_default_store"/* "Orphaned pnpm store"
        fi
    else
        # pnpm not installed or not usable, just clean the default store directory
        safe_clean "$pnpm_default_store"/* "pnpm store"
    fi
    note_activity
    safe_clean ~/.tnpm/_cacache/* "tnpm cache directory"
    safe_clean ~/.tnpm/_logs/* "tnpm logs"
    safe_clean ~/.yarn/cache/* "Yarn cache"
    safe_clean ~/.bun/install/cache/* "Bun cache"
}
# Python/pip ecosystem caches.
clean_dev_python() {
    if command -v pip3 > /dev/null 2>&1; then
        clean_tool_cache "pip cache" bash -c 'pip3 cache purge > /dev/null 2>&1 || true'
        note_activity
    fi
    safe_clean ~/.pyenv/cache/* "pyenv cache"
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
}
# Go build/module caches.
clean_dev_go() {
    if command -v go > /dev/null 2>&1; then
        clean_tool_cache "Go cache" bash -c 'go clean -modcache > /dev/null 2>&1 || true; go clean -cache > /dev/null 2>&1 || true'
        note_activity
    fi
}
# Rust/cargo caches.
clean_dev_rust() {
    safe_clean ~/.cargo/registry/cache/* "Rust cargo cache"
    safe_clean ~/.cargo/git/* "Cargo git cache"
    safe_clean ~/.rustup/downloads/* "Rust downloads cache"
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
            hint=" · ${GRAY}${list_cmd}${NC}"
        fi
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} ${tool_name}: ${count} found${hint}"
    fi
}

# Check for multiple Rust toolchains.
check_rust_toolchains() {
    command -v rustup > /dev/null 2>&1 || return 0

    check_multiple_versions \
        "$HOME/.rustup/toolchains" \
        "Rust toolchains" \
        "rustup toolchain list"
}
# Docker caches (guarded by daemon check).
clean_dev_docker() {
    if command -v docker > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            start_section_spinner "Checking Docker daemon..."
            local docker_running=false
            if run_with_timeout 3 docker info > /dev/null 2>&1; then
                docker_running=true
            fi
            stop_section_spinner
            if [[ "$docker_running" == "true" ]]; then
                clean_tool_cache "Docker build cache" docker builder prune -af
            else
                debug_log "Docker daemon not running, skipping Docker cache cleanup"
            fi
        else
            note_activity
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Docker build cache · would clean"
        fi
    fi
    safe_clean ~/.docker/buildx/cache/* "Docker BuildX cache"
}
# Nix garbage collection.
clean_dev_nix() {
    if command -v nix-collect-garbage > /dev/null 2>&1; then
        if [[ "$DRY_RUN" != "true" ]]; then
            clean_tool_cache "Nix garbage collection" nix-collect-garbage --delete-older-than 30d
        else
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Nix garbage collection · would clean"
        fi
        note_activity
    fi
}
# Cloud CLI caches.
clean_dev_cloud() {
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

    if pgrep -x "Xcode" > /dev/null 2>&1; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode is running, skipping documentation cache cleanup"
        note_activity
        return 0
    fi

    local -a index_entries=()
    while IFS= read -r -d '' entry; do
        index_entries+=("$entry")
    done < <(command find "$doc_cache_root" -mindepth 1 -maxdepth 1 \( -name "DeveloperDocumentation.index" -o -name "DeveloperDocumentation*.index" \) -print0 2> /dev/null)

    if [[ ${#index_entries[@]} -le 1 ]]; then
        return 0
    fi

    local -a sorted_entries=()
    while IFS= read -r line; do
        sorted_entries+=("${line#* }")
    done < <(
        for entry in "${index_entries[@]}"; do
            local mtime
            mtime=$(stat -f%m "$entry" 2> /dev/null || echo "0")
            printf '%s %s\n' "$mtime" "$entry"
        done | sort -rn
    )

    local -a stale_entries=()
    local idx=0
    local entry
    for entry in "${sorted_entries[@]}"; do
        if [[ $idx -eq 0 ]]; then
            ((idx++))
            continue
        fi
        stale_entries+=("$entry")
        ((idx++))
    done

    if [[ ${#stale_entries[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        safe_clean "${stale_entries[@]}" "Xcode documentation cache (old indexes)"
        note_activity
        return 0
    fi

    if ! has_sudo_session; then
        if ! ensure_sudo_session "Cleaning Xcode documentation cache requires admin access"; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache cleanup skipped (sudo denied)"
            note_activity
            return 0
        fi
    fi

    local removed_count=0
    local skipped_count=0
    local stale_entry
    for stale_entry in "${stale_entries[@]}"; do
        if should_protect_path "$stale_entry" || is_path_whitelisted "$stale_entry"; then
            skipped_count=$((skipped_count + 1))
            continue
        fi
        if safe_sudo_remove "$stale_entry"; then
            removed_count=$((removed_count + 1))
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode documentation cache · removed ${removed_count} old indexes"
        if [[ $skipped_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · skipped ${skipped_count} protected items"
        fi
        note_activity
    elif [[ $skipped_count -gt 0 ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode documentation cache · nothing to clean"
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · skipped ${skipped_count} protected items"
        note_activity
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode documentation cache · no items removed"
        note_activity
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
        size_kb=$(sudo du -skP "$target_path" 2> /dev/null | command awk 'NR==1 {print $1; exit}' || echo "0")
    else
        size_kb=$(du -skP "$target_path" 2> /dev/null | command awk 'NR==1 {print $1; exit}' || echo "0")
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

    local -a entry_statuses=()
    local -a sorted_candidates=()
    local sorted
    while IFS= read -r sorted; do
        [[ -n "$sorted" ]] && sorted_candidates+=("$sorted")
    done < <(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort)

    echo -e "  ${GRAY}${ICON_LIST}${NC} Xcode runtime volumes · scanning ${#sorted_candidates[@]} entries"
    local runtime_scan_spinner=false
    if [[ -t 1 ]]; then
        start_section_spinner "Scanning Xcode runtime volumes..."
        runtime_scan_spinner=true
    fi

    local in_use_count=0
    local unused_count=0
    for candidate in "${sorted_candidates[@]}"; do
        local status="UNUSED"
        if _sim_runtime_is_path_in_use "$candidate" "${mount_points[@]}"; then
            status="IN_USE"
            in_use_count=$((in_use_count + 1))
        else
            unused_count=$((unused_count + 1))
        fi
        entry_statuses+=("$status")
    done

    if [[ "$DRY_RUN" == "true" ]]; then
        local -a size_values=()
        local in_use_kb=0
        local unused_kb=0
        local i=0
        for candidate in "${sorted_candidates[@]}"; do
            local size_kb
            size_kb=$(_sim_runtime_size_kb "$candidate")
            size_values+=("$size_kb")
            local status="${entry_statuses[$i]:-UNUSED}"
            if [[ "$status" == "IN_USE" ]]; then
                in_use_kb=$((in_use_kb + size_kb))
            else
                unused_kb=$((unused_kb + size_kb))
            fi
            i=$((i + 1))
        done
        if [[ "$runtime_scan_spinner" == "true" ]]; then
            stop_section_spinner
            runtime_scan_spinner=false
        fi

        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Xcode runtime volumes · ${unused_count} unused, ${in_use_count} in use"
        local dryrun_total_kb=$((unused_kb + in_use_kb))
        local dryrun_total_human
        dryrun_total_human=$(bytes_to_human "$((dryrun_total_kb * 1024))")
        local dryrun_unused_human
        dryrun_unused_human=$(bytes_to_human "$((unused_kb * 1024))")
        local dryrun_in_use_human
        dryrun_in_use_human=$(bytes_to_human "$((in_use_kb * 1024))")
        echo -e "  ${GRAY}${ICON_LIST}${NC} Runtime volumes total: ${dryrun_total_human} (unused ${dryrun_unused_human}, in-use ${dryrun_in_use_human})"

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
            line_human=$(bytes_to_human "$((line_size_kb * 1024))")
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

        local total_entries="${#sorted_candidates[@]}"
        if [[ "$total_entries" -gt "$shown" ]]; then
            local remaining=$((total_entries - shown))
            echo -e "    ${GRAY}${ICON_LIST}${NC} ... and ${remaining} more runtime volume entries"
        fi
        note_activity
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
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode runtime volumes · nothing to clean"
        note_activity
        return 0
    fi

    if ! has_sudo_session; then
        if ! ensure_sudo_session "Cleaning Xcode runtime volumes requires admin access"; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode runtime volumes cleanup skipped (sudo denied)"
            note_activity
            return 0
        fi
    fi

    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode runtime volumes · cleaning ${#selected_paths[@]} unused"
    if [[ $skipped_protected -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode runtime volumes · skipped ${skipped_protected} protected items"
    fi

    local removed_count=0
    local removed_size_kb=0
    local selected_path
    for selected_path in "${selected_paths[@]}"; do
        local selected_size_kb=0
        selected_size_kb=$(_sim_runtime_size_kb "$selected_path")
        if safe_sudo_remove "$selected_path"; then
            removed_count=$((removed_count + 1))
            removed_size_kb=$((removed_size_kb + selected_size_kb))
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        local removed_human
        removed_human=$(bytes_to_human "$((removed_size_kb * 1024))")
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode runtime volumes · removed ${removed_count}, ${removed_human}"
        note_activity
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode runtime volumes · no items removed"
        note_activity
    fi
}

clean_dev_mobile() {
    check_android_ndk
    clean_xcode_documentation_cache
    clean_xcode_simulator_runtime_volumes

    if command -v xcrun > /dev/null 2>&1; then
        debug_log "Checking for unavailable Xcode simulators"
        local unavailable_before=0
        local unavailable_after=0
        local removed_unavailable=0
        local unavailable_size_kb=0
        local unavailable_size_human="0B"
        local -a unavailable_udids=()
        local unavailable_udid=""

        unavailable_before=$(xcrun simctl list devices unavailable 2> /dev/null | command awk '/\(unavailable/ { count++ } END { print count+0 }' || echo "0")
        [[ "$unavailable_before" =~ ^[0-9]+$ ]] || unavailable_before=0
        while IFS= read -r unavailable_udid; do
            [[ -n "$unavailable_udid" ]] && unavailable_udids+=("$unavailable_udid")
        done < <(
            xcrun simctl list devices unavailable 2> /dev/null |
                command sed -nE 's/.*\(([0-9A-Fa-f-]{36})\).*\(unavailable.*/\1/p' || true
        )
        if [[ ${#unavailable_udids[@]} -gt 0 ]]; then
            local udid
            for udid in "${unavailable_udids[@]}"; do
                local simulator_device_path="$HOME/Library/Developer/CoreSimulator/Devices/$udid"
                if [[ -d "$simulator_device_path" ]]; then
                    unavailable_size_kb=$((unavailable_size_kb + $(get_path_size_kb "$simulator_device_path")))
                fi
            done
        fi
        unavailable_size_human=$(bytes_to_human "$((unavailable_size_kb * 1024))")

        if [[ "$DRY_RUN" == "true" ]]; then
            if ((unavailable_before > 0)); then
                echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Xcode unavailable simulators · would clean ${unavailable_before}, ${unavailable_size_human}"
            else
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode unavailable simulators · already clean"
            fi
        else
            start_section_spinner "Checking unavailable simulators..."
            if xcrun simctl delete unavailable > /dev/null 2>&1; then
                stop_section_spinner
                unavailable_after=$(xcrun simctl list devices unavailable 2> /dev/null | command awk '/\(unavailable/ { count++ } END { print count+0 }' || echo "0")
                [[ "$unavailable_after" =~ ^[0-9]+$ ]] || unavailable_after=0

                removed_unavailable=$((unavailable_before - unavailable_after))
                if ((removed_unavailable < 0)); then
                    removed_unavailable=0
                fi

                if ((unavailable_before == 0)); then
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode unavailable simulators · already clean"
                elif ((removed_unavailable > 0)); then
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode unavailable simulators · removed ${removed_unavailable}, ${unavailable_size_human}"
                else
                    echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Xcode unavailable simulators · cleanup completed, ${unavailable_size_human}"
                fi
            else
                stop_section_spinner
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode unavailable simulators cleanup failed"
            fi
        fi
        note_activity
    fi
    # DeviceSupport caches/logs (preserve core support files).
    safe_clean ~/Library/Developer/Xcode/iOS\ DeviceSupport/*/Symbols/System/Library/Caches/* "iOS device symbol cache"
    safe_clean ~/Library/Developer/Xcode/iOS\ DeviceSupport/*.log "iOS device support logs"
    safe_clean ~/Library/Developer/Xcode/watchOS\ DeviceSupport/*/Symbols/System/Library/Caches/* "watchOS device symbol cache"
    safe_clean ~/Library/Developer/Xcode/tvOS\ DeviceSupport/*/Symbols/System/Library/Caches/* "tvOS device symbol cache"
    # Simulator runtime caches.
    safe_clean ~/Library/Developer/CoreSimulator/Profiles/Runtimes/*/Contents/Resources/RuntimeRoot/System/Library/Caches/* "Simulator runtime cache"
    safe_clean ~/Library/Caches/Google/AndroidStudio*/* "Android Studio cache"
    # safe_clean ~/Library/Caches/CocoaPods/* "CocoaPods cache"
    # safe_clean ~/.cache/flutter/* "Flutter cache"
    safe_clean ~/.android/build-cache/* "Android build cache"
    safe_clean ~/.android/cache/* "Android SDK cache"
    safe_clean ~/Library/Developer/Xcode/UserData/IB\ Support/* "Xcode Interface Builder cache"
    safe_clean ~/.cache/swift-package-manager/* "Swift package manager cache"
}
# JVM ecosystem caches.
# Gradle excluded (default whitelist, like Maven). Remove via: mo clean --whitelist
clean_dev_jvm() {
    safe_clean ~/.sbt/* "SBT cache"
    safe_clean ~/.ivy2/cache/* "Ivy cache"
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
                    ((idx++))
                    continue
                fi
                safe_clean "$dir_path" "JetBrains Toolbox old IDE version"
                note_activity
                ((idx++))
            done
        done < <(command find "$product_dir" -mindepth 1 -maxdepth 1 -type d -name "ch-*" -print0 2> /dev/null)
    done

    _restore_whitelist
}
# Other language tool caches.
clean_dev_other_langs() {
    safe_clean ~/.bundle/cache/* "Ruby Bundler cache"
    safe_clean ~/.composer/cache/* "PHP Composer cache"
    safe_clean ~/.nuget/packages/* "NuGet packages cache"
    # safe_clean ~/.pub-cache/* "Dart Pub cache"
    safe_clean ~/.cache/bazel/* "Bazel cache"
    safe_clean ~/.cache/zig/* "Zig cache"
    safe_clean ~/Library/Caches/deno/* "Deno cache"
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
# Misc dev tool caches.
clean_dev_misc() {
    safe_clean ~/Library/Caches/com.unity3d.*/* "Unity cache"
    safe_clean ~/Library/Caches/com.mongodb.compass/* "MongoDB Compass cache"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Figma cache"
    safe_clean ~/Library/Caches/com.github.GitHubDesktop/* "GitHub Desktop cache"
    safe_clean ~/Library/Caches/SentryCrash/* "Sentry crash reports"
    safe_clean ~/Library/Caches/KSCrash/* "KSCrash reports"
    safe_clean ~/Library/Caches/com.crashlytics.data/* "Crashlytics data"
    safe_clean ~/Library/Application\ Support/Antigravity/Cache/* "Antigravity cache"
    safe_clean ~/Library/Application\ Support/Antigravity/Code\ Cache/* "Antigravity code cache"
    safe_clean ~/Library/Application\ Support/Antigravity/GPUCache/* "Antigravity GPU cache"
    safe_clean ~/Library/Application\ Support/Antigravity/DawnGraphiteCache/* "Antigravity Dawn cache"
    safe_clean ~/Library/Application\ Support/Antigravity/DawnWebGPUCache/* "Antigravity WebGPU cache"
    # Filo (Electron)
    safe_clean ~/Library/Application\ Support/Filo/production/Cache/* "Filo cache"
    safe_clean ~/Library/Application\ Support/Filo/production/Code\ Cache/* "Filo code cache"
    safe_clean ~/Library/Application\ Support/Filo/production/GPUCache/* "Filo GPU cache"
    safe_clean ~/Library/Application\ Support/Filo/production/DawnGraphiteCache/* "Filo Dawn cache"
    safe_clean ~/Library/Application\ Support/Filo/production/DawnWebGPUCache/* "Filo WebGPU cache"
    # Claude (Electron)
    safe_clean ~/Library/Application\ Support/Claude/Cache/* "Claude cache"
    safe_clean ~/Library/Application\ Support/Claude/Code\ Cache/* "Claude code cache"
    safe_clean ~/Library/Application\ Support/Claude/GPUCache/* "Claude GPU cache"
    safe_clean ~/Library/Application\ Support/Claude/DawnGraphiteCache/* "Claude Dawn cache"
    safe_clean ~/Library/Application\ Support/Claude/DawnWebGPUCache/* "Claude WebGPU cache"
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
# Orphaned SQLite temp files (-shm/-wal). Disabled due to low ROI.
clean_sqlite_temp_files() {
    return 0
}
# Elixir/Erlang ecosystem.
# Note: ~/.mix/archives contains installed Mix tools - excluded from cleanup
clean_dev_elixir() {
    safe_clean ~/.hex/cache/* "Hex cache"
}
# Haskell ecosystem.
# Note: ~/.stack/programs contains Stack-installed GHC compilers - excluded from cleanup
clean_dev_haskell() {
    safe_clean ~/.cabal/packages/* "Cabal install cache"
}
# OCaml ecosystem.
clean_dev_ocaml() {
    safe_clean ~/.opam/download-cache/* "Opam cache"
}
# Editor caches.
# Note: ~/Library/Application Support/Code/User/workspaceStorage contains workspace settings - excluded from cleanup
clean_dev_editors() {
    safe_clean ~/Library/Caches/com.microsoft.VSCode/Cache/* "VS Code cached data"
    safe_clean ~/Library/Application\ Support/Code/CachedData/* "VS Code cached data"
    safe_clean ~/Library/Application\ Support/Code/DawnGraphiteCache/* "VS Code Dawn cache"
    safe_clean ~/Library/Application\ Support/Code/DawnWebGPUCache/* "VS Code WebGPU cache"
    safe_clean ~/Library/Application\ Support/Code/GPUCache/* "VS Code GPU cache"
    safe_clean ~/Library/Application\ Support/Code/CachedExtensionVSIXs/* "VS Code extension cache"
    safe_clean ~/Library/Caches/Zed/* "Zed cache"
}
# Main developer tools cleanup sequence.
clean_developer_tools() {
    stop_section_spinner
    clean_sqlite_temp_files
    clean_dev_npm
    clean_dev_python
    clean_dev_go
    clean_dev_rust
    check_rust_toolchains
    clean_dev_docker
    clean_dev_cloud
    clean_dev_nix
    clean_dev_shell
    clean_dev_frontend
    clean_project_caches
    clean_dev_mobile
    clean_dev_jvm
    clean_dev_jetbrains_toolbox
    clean_dev_other_langs
    clean_dev_cicd
    clean_dev_database
    clean_dev_api_tools
    clean_dev_network
    clean_dev_misc
    clean_dev_elixir
    clean_dev_haskell
    clean_dev_ocaml
    clean_dev_editors
    safe_clean ~/Library/Caches/Homebrew/* "Homebrew cache"
    # Clean Homebrew locks without repeated sudo prompts.
    local brew_lock_dirs=(
        "/opt/homebrew/var/homebrew/locks"
        "/usr/local/var/homebrew/locks"
    )
    for lock_dir in "${brew_lock_dirs[@]}"; do
        if [[ -d "$lock_dir" && -w "$lock_dir" ]]; then
            safe_clean "$lock_dir"/* "Homebrew lock files"
        elif [[ -d "$lock_dir" ]]; then
            if find "$lock_dir" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
                debug_log "Skipping read-only Homebrew locks in $lock_dir"
            fi
        fi
    done
    clean_homebrew
}
