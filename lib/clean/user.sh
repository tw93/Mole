#!/bin/bash
# User Data Cleanup Module
set -euo pipefail
clean_user_essentials() {
    start_section_spinner "Scanning caches..."
    safe_clean ~/Library/Caches/* "User app cache"
    stop_section_spinner

    safe_clean ~/Library/Logs/* "User app logs"

    if ! is_path_whitelisted "$HOME/.Trash"; then
        local trash_count
        trash_count=$(osascript -e 'tell application "Finder" to count items in trash' 2> /dev/null || echo "0")
        [[ "$trash_count" =~ ^[0-9]+$ ]] || trash_count="0"

        if [[ "$DRY_RUN" == "true" ]]; then
            [[ $trash_count -gt 0 ]] && echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Trash · would empty, $trash_count items" || echo -e "  ${GRAY}${ICON_EMPTY}${NC} Trash · already empty"
        elif [[ $trash_count -gt 0 ]]; then
            if osascript -e 'tell application "Finder" to empty trash' > /dev/null 2>&1; then
                echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Trash · emptied, $trash_count items"
                note_activity
            else
                while IFS= read -r -d '' item; do
                    safe_remove "$item" true || true
                done < <(command find "$HOME/.Trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
            fi
        else
            echo -e "  ${GRAY}${ICON_EMPTY}${NC} Trash · already empty"
        fi
    fi
}

# Remove old Google Chrome versions while keeping Current.
clean_chrome_old_versions() {
    local -a app_paths=(
        "/Applications/Google Chrome.app"
        "$HOME/Applications/Google Chrome.app"
    )

    # Match the exact Chrome process name to avoid false positives
    if pgrep -x "Google Chrome" > /dev/null 2>&1; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Google Chrome running · old versions cleanup skipped"
        return 0
    fi

    local cleaned_count=0
    local total_size=0
    local cleaned_any=false

    for app_path in "${app_paths[@]}"; do
        [[ -d "$app_path" ]] || continue

        local versions_dir="$app_path/Contents/Frameworks/Google Chrome Framework.framework/Versions"
        [[ -d "$versions_dir" ]] || continue

        local current_link="$versions_dir/Current"
        [[ -L "$current_link" ]] || continue

        local current_version
        current_version=$(readlink "$current_link" 2> /dev/null || true)
        current_version="${current_version##*/}"
        [[ -n "$current_version" ]] || continue

        local -a old_versions=()
        local dir name
        for dir in "$versions_dir"/*; do
            [[ -d "$dir" ]] || continue
            name=$(basename "$dir")
            [[ "$name" == "Current" ]] && continue
            [[ "$name" == "$current_version" ]] && continue
            if is_path_whitelisted "$dir"; then
                continue
            fi
            old_versions+=("$dir")
        done

        if [[ ${#old_versions[@]} -eq 0 ]]; then
            continue
        fi

        for dir in "${old_versions[@]}"; do
            local size_kb
            size_kb=$(get_path_size_kb "$dir" || echo 0)
            size_kb="${size_kb:-0}"
            total_size=$((total_size + size_kb))
            ((cleaned_count++))
            cleaned_any=true
            if [[ "$DRY_RUN" != "true" ]]; then
                if has_sudo_session; then
                    safe_sudo_remove "$dir" > /dev/null 2>&1 || true
                else
                    safe_remove "$dir" true > /dev/null 2>&1 || true
                fi
            fi
        done
    done

    if [[ "$cleaned_any" == "true" ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Chrome old versions${NC}, ${YELLOW}${cleaned_count} dirs, $size_human dry${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Chrome old versions${NC}, ${GREEN}${cleaned_count} dirs, $size_human${NC}"
        fi
        ((files_cleaned += cleaned_count))
        ((total_size_cleaned += total_size))
        ((total_items++))
        note_activity
    fi
}

# Remove old Microsoft Edge versions while keeping Current.
clean_edge_old_versions() {
    # Allow override for testing
    local -a app_paths
    if [[ -n "${MOLE_EDGE_APP_PATHS:-}" ]]; then
        IFS=':' read -ra app_paths <<< "$MOLE_EDGE_APP_PATHS"
    else
        app_paths=(
            "/Applications/Microsoft Edge.app"
            "$HOME/Applications/Microsoft Edge.app"
        )
    fi

    # Match the exact Edge process name to avoid false positives (e.g., Microsoft Teams)
    if pgrep -x "Microsoft Edge" > /dev/null 2>&1; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Microsoft Edge running · old versions cleanup skipped"
        return 0
    fi

    local cleaned_count=0
    local total_size=0
    local cleaned_any=false

    for app_path in "${app_paths[@]}"; do
        [[ -d "$app_path" ]] || continue

        local versions_dir="$app_path/Contents/Frameworks/Microsoft Edge Framework.framework/Versions"
        [[ -d "$versions_dir" ]] || continue

        local current_link="$versions_dir/Current"
        [[ -L "$current_link" ]] || continue

        local current_version
        current_version=$(readlink "$current_link" 2> /dev/null || true)
        current_version="${current_version##*/}"
        [[ -n "$current_version" ]] || continue

        local -a old_versions=()
        local dir name
        for dir in "$versions_dir"/*; do
            [[ -d "$dir" ]] || continue
            name=$(basename "$dir")
            [[ "$name" == "Current" ]] && continue
            [[ "$name" == "$current_version" ]] && continue
            if is_path_whitelisted "$dir"; then
                continue
            fi
            old_versions+=("$dir")
        done

        if [[ ${#old_versions[@]} -eq 0 ]]; then
            continue
        fi

        for dir in "${old_versions[@]}"; do
            local size_kb
            size_kb=$(get_path_size_kb "$dir" || echo 0)
            size_kb="${size_kb:-0}"
            total_size=$((total_size + size_kb))
            ((cleaned_count++))
            cleaned_any=true
            if [[ "$DRY_RUN" != "true" ]]; then
                if has_sudo_session; then
                    safe_sudo_remove "$dir" > /dev/null 2>&1 || true
                else
                    safe_remove "$dir" true > /dev/null 2>&1 || true
                fi
            fi
        done
    done

    if [[ "$cleaned_any" == "true" ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Edge old versions${NC}, ${YELLOW}${cleaned_count} dirs, $size_human dry${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Edge old versions${NC}, ${GREEN}${cleaned_count} dirs, $size_human${NC}"
        fi
        ((files_cleaned += cleaned_count))
        ((total_size_cleaned += total_size))
        ((total_items++))
        note_activity
    fi
}

# Remove old Microsoft EdgeUpdater versions while keeping latest.
clean_edge_updater_old_versions() {
    local updater_dir="$HOME/Library/Application Support/Microsoft/EdgeUpdater/apps/msedge-stable"
    [[ -d "$updater_dir" ]] || return 0

    if pgrep -x "Microsoft Edge" > /dev/null 2>&1; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Microsoft Edge running · updater cleanup skipped"
        return 0
    fi

    local -a version_dirs=()
    local dir
    for dir in "$updater_dir"/*; do
        [[ -d "$dir" ]] || continue
        version_dirs+=("$dir")
    done

    if [[ ${#version_dirs[@]} -lt 2 ]]; then
        return 0
    fi

    local latest_version
    latest_version=$(printf '%s\n' "${version_dirs[@]##*/}" | sort -V | tail -n 1)
    [[ -n "$latest_version" ]] || return 0

    local cleaned_count=0
    local total_size=0
    local cleaned_any=false

    for dir in "${version_dirs[@]}"; do
        local name
        name=$(basename "$dir")
        [[ "$name" == "$latest_version" ]] && continue
        if is_path_whitelisted "$dir"; then
            continue
        fi
        local size_kb
        size_kb=$(get_path_size_kb "$dir" || echo 0)
        size_kb="${size_kb:-0}"
        total_size=$((total_size + size_kb))
        ((cleaned_count++))
        cleaned_any=true
        if [[ "$DRY_RUN" != "true" ]]; then
            safe_remove "$dir" true > /dev/null 2>&1 || true
        fi
    done

    if [[ "$cleaned_any" == "true" ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Edge updater old versions${NC}, ${YELLOW}${cleaned_count} dirs, $size_human dry${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Edge updater old versions${NC}, ${GREEN}${cleaned_count} dirs, $size_human${NC}"
        fi
        ((files_cleaned += cleaned_count))
        ((total_size_cleaned += total_size))
        ((total_items++))
        note_activity
    fi
}

scan_external_volumes() {
    [[ -d "/Volumes" ]] || return 0
    local -a candidate_volumes=()
    local -a network_volumes=()
    for volume in /Volumes/*; do
        [[ -d "$volume" && -w "$volume" && ! -L "$volume" ]] || continue
        [[ "$volume" == "/" || "$volume" == "/Volumes/Macintosh HD" ]] && continue
        local protocol=""
        protocol=$(run_with_timeout 1 command diskutil info "$volume" 2> /dev/null | grep -i "Protocol:" | awk '{print $2}' || echo "")
        case "$protocol" in
            SMB | NFS | AFP | CIFS | WebDAV)
                network_volumes+=("$volume")
                continue
                ;;
        esac
        local fs_type=""
        fs_type=$(run_with_timeout 1 command df -T "$volume" 2> /dev/null | tail -1 | awk '{print $2}' || echo "")
        case "$fs_type" in
            nfs | smbfs | afpfs | cifs | webdav)
                network_volumes+=("$volume")
                continue
                ;;
        esac
        candidate_volumes+=("$volume")
    done
    local volume_count=${#candidate_volumes[@]}
    local network_count=${#network_volumes[@]}
    if [[ $volume_count -eq 0 ]]; then
        if [[ $network_count -gt 0 ]]; then
            echo -e "  ${GRAY}${ICON_LIST}${NC} External volumes, ${network_count} network volumes skipped"
            note_activity
        fi
        return 0
    fi
    start_section_spinner "Scanning $volume_count external volumes..."
    for volume in "${candidate_volumes[@]}"; do
        [[ -d "$volume" && -r "$volume" ]] || continue
        local volume_trash="$volume/.Trashes"
        if [[ -d "$volume_trash" && "$DRY_RUN" != "true" ]] && ! is_path_whitelisted "$volume_trash"; then
            while IFS= read -r -d '' item; do
                safe_remove "$item" true || true
            done < <(command find "$volume_trash" -mindepth 1 -maxdepth 1 -print0 2> /dev/null || true)
        fi
        if [[ "$PROTECT_FINDER_METADATA" != "true" ]]; then
            clean_ds_store_tree "$volume" "$(basename "$volume") volume, .DS_Store"
        fi
    done
    stop_section_spinner
}
# Finder metadata (.DS_Store).
clean_finder_metadata() {
    if [[ "$PROTECT_FINDER_METADATA" == "true" ]]; then
        return
    fi
    clean_ds_store_tree "$HOME" "Home directory, .DS_Store"
}
# macOS system caches and user-level leftovers.
clean_macos_system_caches() {
    # safe_clean already checks protected paths.
    safe_clean ~/Library/Saved\ Application\ State/* "Saved application states" || true
    safe_clean ~/Library/Caches/com.apple.photoanalysisd "Photo analysis cache" || true
    safe_clean ~/Library/Caches/com.apple.akd "Apple ID cache" || true
    safe_clean ~/Library/Caches/com.apple.WebKit.Networking/* "WebKit network cache" || true
    safe_clean ~/Library/DiagnosticReports/* "Diagnostic reports" || true
    safe_clean ~/Library/Caches/com.apple.QuickLook.thumbnailcache "QuickLook thumbnails" || true
    safe_clean ~/Library/Caches/Quick\ Look/* "QuickLook cache" || true
    safe_clean ~/Library/Caches/com.apple.iconservices* "Icon services cache" || true
    safe_clean ~/Downloads/*.download "Safari incomplete downloads" || true
    safe_clean ~/Downloads/*.crdownload "Chrome incomplete downloads" || true
    safe_clean ~/Downloads/*.part "Partial incomplete downloads" || true
    safe_clean ~/Library/Autosave\ Information/* "Autosave information" || true
    safe_clean ~/Library/IdentityCaches/* "Identity caches" || true
    safe_clean ~/Library/Suggestions/* "Siri suggestions cache" || true
    safe_clean ~/Library/Calendars/Calendar\ Cache "Calendar cache" || true
    safe_clean ~/Library/Application\ Support/AddressBook/Sources/*/Photos.cache "Address Book photo cache" || true
}
clean_recent_items() {
    local shared_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    local -a recent_lists=(
        "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentServers.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentHosts.sfl2"
        "$shared_dir/com.apple.LSSharedFileList.RecentApplications.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentDocuments.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentServers.sfl"
        "$shared_dir/com.apple.LSSharedFileList.RecentHosts.sfl"
    )
    if [[ -d "$shared_dir" ]]; then
        for sfl_file in "${recent_lists[@]}"; do
            [[ -e "$sfl_file" ]] && safe_clean "$sfl_file" "Recent items list" || true
        done
    fi
    safe_clean ~/Library/Preferences/com.apple.recentitems.plist "Recent items preferences" || true
}
clean_mail_downloads() {
    local mail_age_days=${MOLE_MAIL_AGE_DAYS:-}
    if ! [[ "$mail_age_days" =~ ^[0-9]+$ ]]; then
        mail_age_days=30
    fi
    local -a mail_dirs=(
        "$HOME/Library/Mail Downloads"
        "$HOME/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    )
    local count=0
    local cleaned_kb=0
    for target_path in "${mail_dirs[@]}"; do
        if [[ -d "$target_path" ]]; then
            local dir_size_kb=0
            dir_size_kb=$(get_path_size_kb "$target_path")
            if ! [[ "$dir_size_kb" =~ ^[0-9]+$ ]]; then
                dir_size_kb=0
            fi
            local min_kb="${MOLE_MAIL_DOWNLOADS_MIN_KB:-}"
            if ! [[ "$min_kb" =~ ^[0-9]+$ ]]; then
                min_kb=5120
            fi
            if [[ "$dir_size_kb" -lt "$min_kb" ]]; then
                continue
            fi
            while IFS= read -r -d '' file_path; do
                if [[ -f "$file_path" ]]; then
                    local file_size_kb=$(get_path_size_kb "$file_path")
                    if safe_remove "$file_path" true; then
                        ((count++))
                        ((cleaned_kb += file_size_kb))
                    fi
                fi
            done < <(command find "$target_path" -type f -mtime +"$mail_age_days" -print0 2> /dev/null || true)
        fi
    done
    if [[ $count -gt 0 ]]; then
        local cleaned_mb=$(echo "$cleaned_kb" | awk '{printf "%.1f", $1/1024}' || echo "0.0")
        echo "  ${GREEN}${ICON_SUCCESS}${NC} Cleaned $count mail attachments, about ${cleaned_mb}MB"
        note_activity
    fi
}
# Sandboxed app caches.
clean_sandboxed_app_caches() {
    stop_section_spinner
    safe_clean ~/Library/Containers/com.apple.wallpaper.agent/Data/Library/Caches/* "Wallpaper agent cache"
    safe_clean ~/Library/Containers/com.apple.mediaanalysisd/Data/Library/Caches/* "Media analysis cache"
    safe_clean ~/Library/Containers/com.apple.AppStore/Data/Library/Caches/* "App Store cache"
    safe_clean ~/Library/Containers/com.apple.configurator.xpc.InternetService/Data/tmp/* "Apple Configurator temp files"
    local containers_dir="$HOME/Library/Containers"
    [[ ! -d "$containers_dir" ]] && return 0
    start_section_spinner "Scanning sandboxed apps..."
    local total_size=0
    local cleaned_count=0
    local found_any=false
    # Use nullglob to avoid literal globs.
    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob
    for container_dir in "$containers_dir"/*; do
        process_container_cache "$container_dir"
    done
    eval "$_ng_state"
    stop_section_spinner
    if [[ "$found_any" == "true" ]]; then
        local size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Sandboxed app caches${NC}, ${YELLOW}$size_human dry${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Sandboxed app caches${NC}, ${GREEN}$size_human${NC}"
        fi
        ((files_cleaned += cleaned_count))
        ((total_size_cleaned += total_size))
        ((total_items++))
        note_activity
    fi
}
# Process a single container cache directory.
process_container_cache() {
    local container_dir="$1"
    [[ -d "$container_dir" ]] || return 0
    local bundle_id=$(basename "$container_dir")
    if is_critical_system_component "$bundle_id"; then
        return 0
    fi
    if should_protect_data "$bundle_id" || should_protect_data "$(echo "$bundle_id" | LC_ALL=C tr '[:upper:]' '[:lower:]')"; then
        return 0
    fi
    local cache_dir="$container_dir/Data/Library/Caches"
    [[ -d "$cache_dir" ]] || return 0
    # Fast non-empty check.
    if find "$cache_dir" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
        local size=$(get_path_size_kb "$cache_dir")
        ((total_size += size))
        found_any=true
        ((cleaned_count++))
        if [[ "$DRY_RUN" != "true" ]]; then
            # Clean contents safely with local nullglob.
            local _ng_state
            _ng_state=$(shopt -p nullglob || true)
            shopt -s nullglob
            for item in "$cache_dir"/*; do
                [[ -e "$item" ]] || continue
                safe_remove "$item" true || true
            done
            eval "$_ng_state"
        fi
    fi
}
# Browser caches (Safari/Chrome/Edge/Firefox).
clean_browsers() {
    safe_clean ~/Library/Caches/com.apple.Safari/* "Safari cache"
    # Chrome/Chromium.
    safe_clean ~/Library/Caches/Google/Chrome/* "Chrome cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/Application\ Cache/* "Chrome app cache"
    safe_clean ~/Library/Application\ Support/Google/Chrome/*/GPUCache/* "Chrome GPU cache"
    safe_clean ~/Library/Caches/Chromium/* "Chromium cache"
    safe_clean ~/.cache/puppeteer/* "Puppeteer browser cache"
    safe_clean ~/Library/Caches/com.microsoft.edgemac/* "Edge cache"
    safe_clean ~/Library/Caches/company.thebrowser.Browser/* "Arc cache"
    safe_clean ~/Library/Caches/company.thebrowser.dia/* "Dia cache"
    safe_clean ~/Library/Caches/BraveSoftware/Brave-Browser/* "Brave cache"
    # Yandex Browser.
    safe_clean ~/Library/Caches/Yandex/YandexBrowser/* "Yandex cache"
    safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/ShaderCache/* "Yandex shader cache"
    safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/GrShaderCache/* "Yandex GR shader cache"
    safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/GraphiteDawnCache/* "Yandex Dawn cache"
    safe_clean ~/Library/Application\ Support/Yandex/YandexBrowser/*/GPUCache/* "Yandex GPU cache"
    local firefox_running=false
    if pgrep -x "Firefox" > /dev/null 2>&1; then
        firefox_running=true
    fi
    if [[ "$firefox_running" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Firefox is running · cache cleanup skipped"
    else
        safe_clean ~/Library/Caches/Firefox/* "Firefox cache"
    fi
    safe_clean ~/Library/Caches/com.operasoftware.Opera/* "Opera cache"
    safe_clean ~/Library/Caches/com.vivaldi.Vivaldi/* "Vivaldi cache"
    safe_clean ~/Library/Caches/Comet/* "Comet cache"
    safe_clean ~/Library/Caches/com.kagi.kagimacOS/* "Orion cache"
    safe_clean ~/Library/Caches/zen/* "Zen cache"
    if [[ "$firefox_running" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Firefox is running · profile cache cleanup skipped"
    else
        safe_clean ~/Library/Application\ Support/Firefox/Profiles/*/cache2/* "Firefox profile cache"
    fi
    clean_chrome_old_versions
    clean_edge_old_versions
    clean_edge_updater_old_versions
}
# Cloud storage caches.
clean_cloud_storage() {
    safe_clean ~/Library/Caches/com.dropbox.* "Dropbox cache"
    safe_clean ~/Library/Caches/com.getdropbox.dropbox "Dropbox cache"
    safe_clean ~/Library/Caches/com.google.GoogleDrive "Google Drive cache"
    safe_clean ~/Library/Caches/com.baidu.netdisk "Baidu Netdisk cache"
    safe_clean ~/Library/Caches/com.alibaba.teambitiondisk "Alibaba Cloud cache"
    safe_clean ~/Library/Caches/com.box.desktop "Box cache"
    safe_clean ~/Library/Caches/com.microsoft.OneDrive "OneDrive cache"
}
# Office app caches.
clean_office_applications() {
    safe_clean ~/Library/Caches/com.microsoft.Word "Microsoft Word cache"
    safe_clean ~/Library/Caches/com.microsoft.Excel "Microsoft Excel cache"
    safe_clean ~/Library/Caches/com.microsoft.Powerpoint "Microsoft PowerPoint cache"
    safe_clean ~/Library/Caches/com.microsoft.Outlook/* "Microsoft Outlook cache"
    safe_clean ~/Library/Caches/com.apple.iWork.* "Apple iWork cache"
    safe_clean ~/Library/Caches/com.kingsoft.wpsoffice.mac "WPS Office cache"
    safe_clean ~/Library/Caches/org.mozilla.thunderbird/* "Thunderbird cache"
    safe_clean ~/Library/Caches/com.apple.mail/* "Apple Mail cache"
}
# Virtualization caches.
clean_virtualization_tools() {
    stop_section_spinner
    safe_clean ~/Library/Caches/com.vmware.fusion "VMware Fusion cache"
    safe_clean ~/Library/Caches/com.parallels.* "Parallels cache"
    safe_clean ~/VirtualBox\ VMs/.cache "VirtualBox cache"
    safe_clean ~/.vagrant.d/tmp/* "Vagrant temporary files"
}
# Application Support logs/caches.
clean_application_support_logs() {
    if [[ ! -d "$HOME/Library/Application Support" ]] || ! ls "$HOME/Library/Application Support" > /dev/null 2>&1; then
        note_activity
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Skipped: No permission to access Application Support"
        return 0
    fi
    start_section_spinner "Scanning Application Support..."
    local total_size=0
    local cleaned_count=0
    local found_any=false
    # Enable nullglob for safe globbing.
    local _ng_state
    _ng_state=$(shopt -p nullglob || true)
    shopt -s nullglob
    for app_dir in ~/Library/Application\ Support/*; do
        [[ -d "$app_dir" ]] || continue
        local app_name=$(basename "$app_dir")
        local app_name_lower=$(echo "$app_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
        local is_protected=false
        if should_protect_data "$app_name"; then
            is_protected=true
        elif should_protect_data "$app_name_lower"; then
            is_protected=true
        fi
        if [[ "$is_protected" == "true" ]]; then
            continue
        fi
        if is_critical_system_component "$app_name"; then
            continue
        fi
        local -a start_candidates=("$app_dir/log" "$app_dir/logs" "$app_dir/activitylog" "$app_dir/Cache/Cache_Data" "$app_dir/Crashpad/completed")
        for candidate in "${start_candidates[@]}"; do
            if [[ -d "$candidate" ]]; then
                if find "$candidate" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
                    local size=$(get_path_size_kb "$candidate")
                    ((total_size += size))
                    ((cleaned_count++))
                    found_any=true
                    if [[ "$DRY_RUN" != "true" ]]; then
                        for item in "$candidate"/*; do
                            [[ -e "$item" ]] || continue
                            safe_remove "$item" true > /dev/null 2>&1 || true
                        done
                    fi
                fi
            fi
        done
    done
    # Group Containers logs (explicit allowlist).
    local known_group_containers=(
        "group.com.apple.contentdelivery"
    )
    for container in "${known_group_containers[@]}"; do
        local container_path="$HOME/Library/Group Containers/$container"
        local -a gc_candidates=("$container_path/Logs" "$container_path/Library/Logs")
        for candidate in "${gc_candidates[@]}"; do
            if [[ -d "$candidate" ]]; then
                if find "$candidate" -mindepth 1 -maxdepth 1 -print -quit 2> /dev/null | grep -q .; then
                    local size=$(get_path_size_kb "$candidate")
                    ((total_size += size))
                    ((cleaned_count++))
                    found_any=true
                    if [[ "$DRY_RUN" != "true" ]]; then
                        for item in "$candidate"/*; do
                            [[ -e "$item" ]] || continue
                            safe_remove "$item" true > /dev/null 2>&1 || true
                        done
                    fi
                fi
            fi
        done
    done
    eval "$_ng_state"
    stop_section_spinner
    if [[ "$found_any" == "true" ]]; then
        local size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Application Support logs/caches${NC}, ${YELLOW}$size_human dry${NC}"
        else
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Application Support logs/caches${NC}, ${GREEN}$size_human${NC}"
        fi
        ((files_cleaned += cleaned_count))
        ((total_size_cleaned += total_size))
        ((total_items++))
        note_activity
    fi
}
# iOS device backup info.
check_ios_device_backups() {
    local backup_dir="$HOME/Library/Application Support/MobileSync/Backup"
    # Simplified check without find to avoid hanging.
    if [[ -d "$backup_dir" ]]; then
        local backup_kb=$(get_path_size_kb "$backup_dir")
        if [[ -n "${backup_kb:-}" && "$backup_kb" -gt 102400 ]]; then
            local backup_human=$(command du -sh "$backup_dir" 2> /dev/null | awk '{print $1}')
            if [[ -n "$backup_human" ]]; then
                note_activity
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} iOS backups: ${GREEN}${backup_human}${NC}${GRAY}, Path: $backup_dir${NC}"
            fi
        fi
    fi
    return 0
}

# Large file candidates (report only, no deletion).
check_large_file_candidates() {
    local threshold_kb=$((1024 * 1024)) # 1GB
    local found_any=false

    local mail_dir="$HOME/Library/Mail"
    if [[ -d "$mail_dir" ]]; then
        local mail_kb
        mail_kb=$(get_path_size_kb "$mail_dir")
        if [[ "$mail_kb" -ge "$threshold_kb" ]]; then
            local mail_human
            mail_human=$(bytes_to_human "$((mail_kb * 1024))")
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Mail data: ${GREEN}${mail_human}${NC}${GRAY}, Path: $mail_dir${NC}"
            found_any=true
        fi
    fi

    local mail_downloads="$HOME/Library/Mail Downloads"
    if [[ -d "$mail_downloads" ]]; then
        local downloads_kb
        downloads_kb=$(get_path_size_kb "$mail_downloads")
        if [[ "$downloads_kb" -ge "$threshold_kb" ]]; then
            local downloads_human
            downloads_human=$(bytes_to_human "$((downloads_kb * 1024))")
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Mail downloads: ${GREEN}${downloads_human}${NC}${GRAY}, Path: $mail_downloads${NC}"
            found_any=true
        fi
    fi

    local installer_path
    for installer_path in /Applications/Install\ macOS*.app; do
        if [[ -e "$installer_path" ]]; then
            local installer_kb
            installer_kb=$(get_path_size_kb "$installer_path")
            if [[ "$installer_kb" -gt 0 ]]; then
                local installer_human
                installer_human=$(bytes_to_human "$((installer_kb * 1024))")
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} macOS installer: ${GREEN}${installer_human}${NC}${GRAY}, Path: $installer_path${NC}"
                found_any=true
            fi
        fi
    done

    local updates_dir="$HOME/Library/Updates"
    if [[ -d "$updates_dir" ]]; then
        local updates_kb
        updates_kb=$(get_path_size_kb "$updates_dir")
        if [[ "$updates_kb" -ge "$threshold_kb" ]]; then
            local updates_human
            updates_human=$(bytes_to_human "$((updates_kb * 1024))")
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} macOS updates cache: ${GREEN}${updates_human}${NC}${GRAY}, Path: $updates_dir${NC}"
            found_any=true
        fi
    fi

    if [[ "${SYSTEM_CLEAN:-false}" != "true" ]] && command -v tmutil > /dev/null 2>&1; then
        local snapshot_list snapshot_count
        snapshot_list=$(run_with_timeout 3 tmutil listlocalsnapshots / 2> /dev/null || true)
        if [[ -n "$snapshot_list" ]]; then
            snapshot_count=$(echo "$snapshot_list" | { grep -Eo 'com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}' || true; } | wc -l | awk '{print $1}')
            if [[ "$snapshot_count" =~ ^[0-9]+$ && "$snapshot_count" -gt 0 ]]; then
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Time Machine local snapshots: ${GREEN}${snapshot_count}${NC}${GRAY}, Review: tmutil listlocalsnapshots /${NC}"
                found_any=true
            fi
        fi
    fi

    if command -v docker > /dev/null 2>&1; then
        local docker_output
        docker_output=$(run_with_timeout 3 docker system df --format '{{.Type}}\t{{.Size}}\t{{.Reclaimable}}' 2> /dev/null || true)
        if [[ -n "$docker_output" ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Docker storage:"
            while IFS=$'\t' read -r dtype dsize dreclaim; do
                [[ -z "$dtype" ]] && continue
                echo -e "    ${GRAY}• $dtype: $dsize, Reclaimable: $dreclaim${NC}"
            done <<< "$docker_output"
            found_any=true
        else
            docker_output=$(run_with_timeout 3 docker system df 2> /dev/null || true)
            if [[ -n "$docker_output" ]]; then
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Docker storage:"
                echo -e "    ${GRAY}• Run: docker system df${NC}"
                found_any=true
            fi
        fi
    fi

    if [[ "$found_any" == "false" ]]; then
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} No large items detected in common locations"
    fi

    note_activity
    return 0
}
# Apple Silicon specific caches (IS_M_SERIES).
clean_apple_silicon_caches() {
    if [[ "${IS_M_SERIES:-false}" != "true" ]]; then
        return 0
    fi
    start_section "Apple Silicon updates"
    safe_clean /Library/Apple/usr/share/rosetta/rosetta_update_bundle "Rosetta 2 cache"
    safe_clean ~/Library/Caches/com.apple.rosetta.update "Rosetta 2 user cache"
    safe_clean ~/Library/Caches/com.apple.amp.mediasevicesd "Apple Silicon media service cache"
    end_section
}
