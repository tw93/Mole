#!/bin/bash
# User GUI Applications Cleanup Module (desktop apps, media, utilities).
set -euo pipefail
# Xcode DerivedData cleanup with project count and size reporting.
# Fully regenerated on next build — safe to remove.
clean_xcode_derived_data() {
    local dd_dir="$HOME/Library/Developer/Xcode/DerivedData"

    [[ -d "$dd_dir" ]] || return 0

    # Skip while Xcode is running to avoid build failures.
    if pgrep -x "Xcode" > /dev/null 2>&1; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode is running, skipping DerivedData cleanup"
        return 0
    fi

    # Count projects (each subdirectory is a project build).
    local -a projects=()
    while IFS= read -r -d '' dir; do
        projects+=("$dir")
    done < <(command find "$dd_dir" -mindepth 1 -maxdepth 1 -type d -print0 2> /dev/null || true)

    local project_count=${#projects[@]}
    [[ $project_count -eq 0 ]] && return 0

    # Calculate total size.
    local size_kb=0
    size_kb=$(du -skP "$dd_dir" 2> /dev/null | awk '{print $1}') || size_kb=0
    local size_human
    size_human=$(bytes_to_human "$((size_kb * 1024))")

    local project_label="projects"
    [[ $project_count -eq 1 ]] && project_label="project"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Xcode DerivedData · ${project_count} ${project_label}, ${size_human}"
        note_activity
        return 0
    fi

    # Remove all project build dirs using safe_remove.
    local removed=0
    for dir in "${projects[@]}"; do
        if safe_remove "$dir" "true"; then
            removed=$((removed + 1))
        fi
    done

    if [[ $removed -gt 0 ]]; then
        local line_color
        line_color=$(cleanup_result_color_kb "$size_kb" 2> /dev/null || echo "$GREEN")
        echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode DerivedData · ${project_count} ${project_label}, ${line_color}${size_human}${NC}"
        files_cleaned=$((${files_cleaned:-0} + removed))
        total_size_cleaned=$((${total_size_cleaned:-0} + size_kb))
        total_items=$((${total_items:-0} + removed))
        note_activity
    fi
}
# Xcode and iOS tooling.
clean_xcode_tools() {
    # Skip DerivedData/Archives while Xcode is running.
    local xcode_running=false
    if pgrep -x "Xcode" > /dev/null 2>&1; then
        xcode_running=true
    fi
    # Skip Simulator caches/temp files while Simulator is running to avoid crashes.
    local simulator_running=false
    if pgrep -x "Simulator" > /dev/null 2>&1; then
        simulator_running=true
    fi
    if [[ "$simulator_running" == "false" ]]; then
        safe_clean ~/Library/Developer/CoreSimulator/Caches/* "Simulator cache"
        safe_clean ~/Library/Developer/CoreSimulator/Devices/*/data/tmp/* "Simulator temp files"
        safe_clean ~/Library/Logs/CoreSimulator/* "CoreSimulator logs"
        # Remove unavailable simulator devices (not supported by the current Xcode SDK).
        # run_with_timeout guards against xcrun blocking when only CLT is installed
        # (can launch an invisible install dialog or wait on CoreSimulator XPC indefinitely).
        if command -v xcrun > /dev/null 2>&1; then
            local unavail_count
            local unavailable_devices_output=""

            # Tests may mock xcrun as a shell function. Timeout wrappers execute
            # in a separate process and cannot reliably invoke exported functions.
            # Prefer direct function invocation in that case.
            if declare -F xcrun > /dev/null 2>&1; then
                unavailable_devices_output=$(xcrun simctl list devices unavailable 2> /dev/null || true)
            else
                unavailable_devices_output=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" xcrun simctl list devices unavailable 2> /dev/null || true)
                if [[ -z "$unavailable_devices_output" ]]; then
                    unavailable_devices_output=$(xcrun simctl list devices unavailable 2> /dev/null || true)
                fi
            fi
            unavail_count=$(printf '%s\n' "$unavailable_devices_output" | command awk '/\([0-9A-F-]{36}\)/ { count++ } END { print count+0 }')
            [[ "$unavail_count" =~ ^[0-9]+$ ]] || unavail_count=0
            if [[ "$unavail_count" -gt 0 ]]; then
                if [[ "${DRY_RUN:-false}" == "true" ]]; then
                    echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Unavailable simulators · would delete ${unavail_count} devices"
                else
                    # Capture exit code so a timeout (124) or simctl error
                    # is reported instead of falsely echoing SUCCESS.
                    local _delete_rc=0
                    if declare -F xcrun > /dev/null 2>&1; then
                        xcrun simctl delete unavailable > /dev/null 2>&1 || _delete_rc=$?
                    else
                        run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" xcrun simctl delete unavailable > /dev/null 2>&1 || _delete_rc=$?
                    fi
                    if [[ $_delete_rc -eq 0 ]]; then
                        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} Unavailable simulators · deleted ${unavail_count} devices"
                    else
                        echo -e "  ${YELLOW}${ICON_WARNING}${NC} Unavailable simulators · simctl delete failed (exit=${_delete_rc})"
                        debug_log "xcrun simctl delete unavailable returned $_delete_rc"
                    fi
                fi
                note_activity
            fi
        fi
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Simulator is running, skipping Simulator cache/temp/log cleanup"
    fi
    safe_clean ~/Library/Caches/com.apple.dt.Xcode/* "Xcode cache"
    safe_clean ~/Library/Developer/Xcode/iOS\ Device\ Logs/* "iOS device logs"
    safe_clean ~/Library/Developer/Xcode/watchOS\ Device\ Logs/* "watchOS device logs"
    safe_clean ~/Library/Developer/Xcode/Products/* "Xcode build products"
    if [[ "$xcode_running" == "false" ]]; then
        clean_xcode_derived_data
        safe_clean ~/Library/Developer/Xcode/DocumentationCache/* "Xcode documentation cache"
        safe_clean ~/Library/Developer/Xcode/DocumentationIndex/* "Xcode documentation index"
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode is running, skipping DerivedData/Documentation cleanup"
    fi
}
# Remove extension directories that VS Code / Cursor have marked obsolete.
# Each editor writes a .obsolete JSON file under its extensions root whose keys
# are stale extension directory names left behind after an extension update.
clean_editor_obsolete_extensions() {
    local -a editor_roots=(
        "$HOME/.vscode/extensions|VS Code"
        "$HOME/.vscode-insiders/extensions|VS Code Insiders"
        "$HOME/.cursor/extensions|Cursor"
    )
    local entry ext_root editor_label obsolete_file key target
    for entry in "${editor_roots[@]}"; do
        ext_root="${entry%%|*}"
        editor_label="${entry##*|}"
        obsolete_file="$ext_root/.obsolete"
        [[ -f "$obsolete_file" ]] || continue

        while IFS= read -r key; do
            # Each key must be a plain direct-child directory name; reject
            # anything that could escape the extensions root.
            case "$key" in
                "" | "." | ".." | */*) continue ;;
            esac
            target="$ext_root/$key"
            [[ -d "$target" ]] || continue
            safe_clean "$target" "Obsolete $editor_label extension"
        done < <(plutil -p "$obsolete_file" 2> /dev/null |
            sed -nE 's/^[[:space:]]*"([^"]+)"[[:space:]]*=>.*/\1/p')
    done
}
# Code editors.
clean_code_editors() {
    safe_clean ~/Library/Application\ Support/Code/logs/* "VS Code logs"
    safe_clean ~/Library/Application\ Support/Code/Cache/* "VS Code cache"
    safe_clean ~/Library/Application\ Support/Code/CachedExtensions/* "VS Code extension cache"
    safe_clean ~/Library/Application\ Support/Code/CachedData/* "VS Code data cache"
    safe_clean ~/Library/Caches/com.sublimetext.*/* "Sublime Text cache"
    safe_clean ~/Library/Caches/Zed/* "Zed cache"
    safe_clean ~/Library/Logs/Zed/* "Zed logs"
    clean_editor_obsolete_extensions
    # CodeBuddy Extension (VS Code fork, Electron)
    if [[ -d ~/Library/Application\ Support/CodeBuddyExtension ]]; then
        safe_clean ~/Library/Application\ Support/CodeBuddyExtension/Cache/* "CodeBuddy Extension cache"
        safe_clean ~/Library/Application\ Support/CodeBuddyExtension/logs/* "CodeBuddy Extension logs"
    fi
    # CodeBuddy CN (VS Code fork, Electron)
    if [[ -d ~/Library/Application\ Support/CodeBuddy\ CN ]]; then
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/Cache/* "CodeBuddy CN cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/CachedData/* "CodeBuddy CN cached data"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/CachedExtensionVSIXs/* "CodeBuddy CN extension cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/Code\ Cache/* "CodeBuddy CN code cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/GPUCache/* "CodeBuddy CN GPU cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/DawnGraphiteCache/* "CodeBuddy CN Dawn cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/DawnWebGPUCache/* "CodeBuddy CN WebGPU cache"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/logs/* "CodeBuddy CN logs"
    fi
}
# Communication apps.
clean_communication_apps() {
    safe_clean ~/Library/Application\ Support/discord/Cache/* "Discord cache"
    safe_clean ~/Library/Application\ Support/legcord/Cache/* "Legcord cache"
    safe_clean ~/Library/Application\ Support/Slack/Cache/* "Slack cache"
    safe_clean ~/Library/Caches/us.zoom.xos/* "Zoom cache"
    safe_clean ~/Library/Caches/com.tencent.xinWeChat/* "WeChat cache"
    safe_clean ~/Library/Caches/ru.keepcoder.Telegram/* "Telegram cache"

    safe_clean ~/Library/Caches/com.microsoft.teams2/* "Microsoft Teams cache"
    safe_clean ~/Library/Caches/net.whatsapp.WhatsApp/* "WhatsApp cache"
    safe_clean ~/Library/Caches/com.skype.skype/* "Skype cache"
    safe_clean ~/Library/Caches/com.tencent.meeting/* "Tencent Meeting cache"
    safe_clean ~/Library/Caches/com.tencent.WeWorkMac/* "WeCom cache"
    safe_clean ~/Library/Caches/com.feishu.*/* "Feishu cache"
    if [[ -d ~/Library/Application\ Support/Microsoft/Teams ]]; then
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Cache/* "Microsoft Teams legacy cache"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Application\ Cache/* "Microsoft Teams legacy application cache"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Code\ Cache/* "Microsoft Teams legacy code cache"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/GPUCache/* "Microsoft Teams legacy GPU cache"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/logs/* "Microsoft Teams legacy logs"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/tmp/* "Microsoft Teams legacy temp files"
    fi
}
# DingTalk.
clean_dingtalk() {
    safe_clean ~/Library/Caches/dd.work.exclusive4aliding/* "DingTalk iDingTalk cache"
    safe_clean ~/Library/Caches/com.alibaba.AliLang.osx/* "AliLang security component"
    if [[ -d ~/Library/Application\ Support/iDingTalk ]]; then
        safe_clean ~/Library/Application\ Support/iDingTalk/log/* "DingTalk logs"
        safe_clean ~/Library/Application\ Support/iDingTalk/holmeslogs/* "DingTalk holmes logs"
    fi
}
# AI assistants.
clean_ai_apps() {
    safe_clean ~/Library/Caches/com.openai.chat/* "ChatGPT cache"
    safe_clean ~/Library/Caches/com.anthropic.claudefordesktop/* "Claude desktop cache"
    safe_clean ~/Library/Logs/Claude/* "Claude logs"
    if [[ -d "$HOME/Library/Application Support/Codex" || -d "$HOME/Library/Logs/com.openai.codex" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Codex Desktop state · skipped by default"
        note_activity
    fi
}
# Design and creative tools.
clean_design_tools() {
    safe_clean ~/Library/Caches/com.bohemiancoding.sketch3/* "Sketch cache"
    safe_clean ~/Library/Application\ Support/com.bohemiancoding.sketch3/cache/* "Sketch app cache"
    safe_clean ~/Library/Caches/Adobe/* "Adobe cache"
    safe_clean ~/Library/Caches/com.adobe.*/* "Adobe app caches"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Figma cache"
    safe_clean ~/Library/Application\ Support/Adobe/Common/Media\ Cache\ Files/* "Adobe media cache files"
}
# Video editing tools.
final_cut_pro_is_running() {
    command -v pgrep > /dev/null 2>&1 || return 1

    pgrep -x "Final Cut Pro" > /dev/null 2>&1 && return 0
    pgrep -f "/Final Cut Pro.app/" > /dev/null 2>&1 && return 0
    return 1
}

final_cut_pro_path_has_protected_component() {
    local path="$1"

    case "$path" in
        */Original\ Media | */Original\ Media/* | \
            */CurrentVersion.flexolibrary | */CurrentVersion.plist | */Settings.plist | \
            */Motion\ Templates | */Motion\ Templates/* | \
            */Final\ Cut\ Pro\ Backups | */Final\ Cut\ Pro\ Backups/*)
            return 0
            ;;
    esac

    return 1
}

is_final_cut_pro_generated_cache_target() {
    local library="$1"
    local target="$2"

    [[ -n "$library" && -n "$target" ]] || return 1
    [[ "$library" == /* && "$target" == /* ]] || return 1
    [[ "$library" == "$HOME"/Movies/*.fcpbundle ]] || return 1
    [[ "$target" == "$library"/* ]] || return 1
    [[ -d "$library" && ! -L "$library" ]] || return 1
    [[ -d "$target" && ! -L "$target" ]] || return 1

    final_cut_pro_path_has_protected_component "$target" && return 1

    if declare -f validate_path_for_deletion > /dev/null 2>&1; then
        validate_path_for_deletion "$target" > /dev/null 2>&1 || return 1
    fi

    local relative_target="${target#"$library"/}"
    case "$relative_target" in
        */Render\ Files/High\ Quality\ Media | */Transcoded\ Media/Proxy\ Media)
            return 0
            ;;
    esac

    return 1
}

find_final_cut_pro_generated_cache_targets() {
    local movies_dir="$HOME/Movies"
    [[ -d "$movies_dir" ]] || return 0

    local library target
    while IFS= read -r -d '' library; do
        [[ -d "$library" && ! -L "$library" ]] || continue

        while IFS= read -r -d '' target; do
            if is_final_cut_pro_generated_cache_target "$library" "$target"; then
                printf '%s\0' "$target"
            fi
        done < <(command find "$library" \
            \( -type d \( \
            -name "Original Media" -o \
            -name "Analysis Files" -o \
            -name "Motion Templates" -o \
            -name "Final Cut Pro Backups" \
            \) -prune \) -o \
            \( -type d \( \
            -path "*/Render Files/High Quality Media" -o \
            -path "*/Transcoded Media/Proxy Media" \
            \) -print0 \) 2> /dev/null || true)
    done < <(command find "$movies_dir" -maxdepth 4 -type d -name "*.fcpbundle" -prune -print0 2> /dev/null || true)
}

clean_final_cut_pro_generated_caches() {
    if final_cut_pro_is_running; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Final Cut Pro is running, skipping generated cache cleanup"
        note_activity
        return 0
    fi

    local -a fcp_cache_targets=()
    local target
    while IFS= read -r -d '' target; do
        fcp_cache_targets+=("$target")
    done < <(find_final_cut_pro_generated_cache_targets)

    [[ ${#fcp_cache_targets[@]} -gt 0 ]] || return 0

    # Final Cut Pro generated cache cleanup (issue #843).
    # Safety scope for the first pass:
    # - only scan ~/Movies, the default Apple library location;
    # - only delete exact generated-media directories documented by Apple as
    #   regenerable: render media and proxy media;
    # - never touch Original Media, library databases, plist settings, backups,
    #   Motion templates, Analysis Files, optimized media, or external .fcpcache.
    # Future expansion can add explicit flags or configurable roots for
    # optimized media, Analysis Files, and external cache bundles after more
    # field feedback.
    safe_clean "${fcp_cache_targets[@]}" "Final Cut Pro generated cache"
}

clean_video_tools() {
    safe_clean ~/Library/Caches/net.telestream.screenflow10/* "ScreenFlow cache"
    safe_clean ~/Library/Caches/com.apple.FinalCut/* "Final Cut Pro cache"
    clean_final_cut_pro_generated_caches
    safe_clean ~/Library/Caches/com.blackmagic-design.DaVinciResolve/* "DaVinci Resolve cache"
    safe_clean ~/Movies/CacheClip/* "DaVinci Resolve CacheClip"
    safe_clean ~/Library/Caches/com.adobe.PremierePro.*/* "Premiere Pro cache"
}
# 3D and CAD tools.
clean_3d_tools() {
    safe_clean ~/Library/Caches/org.blenderfoundation.blender/* "Blender cache"
    safe_clean ~/Library/Caches/com.maxon.cinema4d/* "Cinema 4D cache"
    safe_clean ~/Library/Caches/com.autodesk.*/* "Autodesk cache"
    safe_clean ~/Library/Caches/com.sketchup.*/* "SketchUp cache"
}
# Productivity apps.
clean_productivity_apps() {
    safe_clean ~/Library/Caches/com.tw93.MiaoYan/* "MiaoYan cache"
    safe_clean ~/Library/Caches/com.klee.desktop/* "Klee cache"
    safe_clean ~/Library/Caches/klee_desktop/* "Klee desktop cache"
    safe_clean ~/Library/Caches/com.orabrowser.app/* "Ora browser cache"
    safe_clean ~/Library/Caches/com.filo.client/* "Filo cache"
    safe_clean ~/Library/Caches/com.flomoapp.mac/* "Flomo cache"
    safe_clean ~/Library/Application\ Support/Quark/Cache/videoCache/* "Quark video cache"
    safe_clean ~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Caches/* "NetNewsWire cache"
    safe_clean ~/Library/Containers/com.ideasoncanvas.mindnode/Data/Library/Caches/* "MindNode cache"
    safe_clean ~/.cache/kaku/* "Kaku cache"
    safe_clean ~/Library/Application\ Support/spacedrive/thumbnails/* "Spacedrive thumbnail cache"
}
# Music/media players (protect Spotify offline music).
clean_media_players() {
    local spotify_cache="$HOME/Library/Caches/com.spotify.client"
    local spotify_data="$HOME/Library/Application Support/Spotify"
    local has_offline_music=false
    # offline.bnk exists even with no offline downloads; only treat it as evidence
    # when it has real content (>1 KB). Encrypted track blobs (*.file) are reliable.
    local bnk_file="$spotify_data/PersistentCache/Storage/offline.bnk"
    local bnk_size=0
    [[ -f "$bnk_file" ]] && bnk_size=$(stat -f%z "$bnk_file" 2> /dev/null || echo 0)
    if [[ $bnk_size -gt 1024 ]] ||
        [[ -d "$spotify_data/PersistentCache/Storage" && -n "$(find "$spotify_data/PersistentCache/Storage" -type f -name "*.file" 2> /dev/null | head -1)" ]]; then
        has_offline_music=true
    fi
    if [[ "$has_offline_music" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Spotify cache protected · offline music detected"
        note_activity
    else
        safe_clean ~/Library/Caches/com.spotify.client/* "Spotify cache"
    fi
    safe_clean ~/Library/Caches/com.apple.Music "Apple Music cache"
    safe_clean ~/Library/Caches/com.apple.podcasts "Apple Podcasts cache"
    # Apple Podcasts sandbox container: zombie sparse files and stale artwork cache (#387)
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/StreamedMedia "Podcasts streamed media"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*.heic "Podcasts artwork cache"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*.img "Podcasts image cache"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*CFNetworkDownload*.tmp "Podcasts download temp"
    safe_clean ~/Library/Caches/com.apple.TV/* "Apple TV cache"
    safe_clean ~/Library/Caches/tv.plex.player.desktop "Plex cache"
    safe_clean ~/Library/Caches/com.netease.163music "NetEase Music cache"
    safe_clean ~/Library/Caches/com.tencent.QQMusic/* "QQ Music cache"
    safe_clean ~/Library/Caches/com.tencent.QQMusicMac/* "QQ Music Mac cache"
    # QQ Music Mac sandboxed container caches (protect offline downloads in iDownloadProxy).
    local _qqmusic_container="$HOME/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac"
    if [[ -d "$_qqmusic_container" ]]; then
        safe_clean "$_qqmusic_container/iRRCache"/* "QQ Music streaming cache"
        safe_clean "$_qqmusic_container/iLog"/* "QQ Music logs"
        safe_clean "$_qqmusic_container/iCache"/* "QQ Music cache"
        safe_clean "$_qqmusic_container/iTemp"/* "QQ Music temp files"
    fi
    safe_clean ~/Library/Containers/com.tencent.QQMusicMac/Data/Library/Caches/* "QQ Music container cache"
    safe_clean ~/Library/Caches/com.kugou.mac/* "Kugou Music cache"
    safe_clean ~/Library/Caches/com.kuwo.mac/* "Kuwo Music cache"
}
# Video players.
clean_video_players() {
    safe_clean ~/Library/Caches/com.colliderli.iina "IINA cache"
    safe_clean ~/Library/Caches/org.videolan.vlc "VLC cache"
    safe_clean ~/Library/Caches/io.mpv "MPV cache"
    safe_clean ~/Library/Caches/com.iqiyi.player "iQIYI cache"
    safe_clean ~/Library/Caches/com.tencent.tenvideo "Tencent Video cache"
    # Tencent Video sandboxed container caches.
    local _tenvideo_as="$HOME/Library/Containers/com.tencent.tenvideo/Data/Library/Application Support"
    if [[ -d "$_tenvideo_as" ]]; then
        safe_clean "$_tenvideo_as/Upgrade"/* "Tencent Video old installer"
        safe_clean "$_tenvideo_as/VideoNative"/* "Tencent Video native cache"
        safe_clean "$_tenvideo_as/documentCache"/* "Tencent Video document cache"
    fi
    safe_clean ~/Library/Caches/tv.danmaku.bili/* "Bilibili cache"
    safe_clean ~/Library/Caches/com.douyu.*/* "Douyu cache"
    safe_clean ~/Library/Caches/com.huya.*/* "Huya cache"
    safe_clean ~/Library/Caches/smart.stremio*/* "Stremio cache"
    if [[ -d ~/Library/Application\ Support/stremio ]]; then
        safe_clean ~/Library/Application\ Support/stremio/stremio-server/stremio-cache/* "Stremio server cache"
    fi
}
# Download managers.
clean_download_managers() {
    safe_clean ~/Library/Caches/net.xmac.aria2gui "Aria2 cache"
    safe_clean ~/Library/Caches/org.m0k.transmission "Transmission cache"
    safe_clean ~/Library/Caches/com.qbittorrent.qBittorrent "qBittorrent cache"
    safe_clean ~/Library/Caches/com.downie.Downie-* "Downie cache"
    safe_clean ~/Library/Caches/com.folx.*/* "Folx cache"
    safe_clean ~/Library/Caches/com.charlessoft.pacifist/* "Pacifist cache"
    clean_neatdm_stale_segments
}
# Neat Download Manager: clean stale incomplete download segments.
# History database (NeatDB.db) is never touched; only numbered segment
# directories whose seg.x0 file is older than MOLE_ORPHAN_AGE_DAYS are removed.
# Download URLs expire within hours/days so 30-day-old segments cannot be resumed.
clean_neatdm_stale_segments() {
    local neatdm_dir="$HOME/Library/Application Support/com.NeatDownloadManager"
    [[ -d "$neatdm_dir" ]] || return 0

    local stale_count=0
    local stale_kb=0
    local current_epoch
    current_epoch=$(get_epoch_seconds)

    local -a stale_dirs=()
    local seg_dir
    for seg_dir in "$neatdm_dir"/*/; do
        [[ -d "$seg_dir" ]] || continue
        local seg_name
        seg_name=$(basename "${seg_dir%/}")
        [[ "$seg_name" =~ ^[0-9]+$ ]] || continue
        [[ -f "$seg_dir/seg.x0" ]] || continue

        local seg_mtime
        seg_mtime=$(get_file_mtime "$seg_dir/seg.x0")
        local age_days=$(((current_epoch - seg_mtime) / 86400))

        if [[ $age_days -ge ${MOLE_ORPHAN_AGE_DAYS:-30} ]]; then
            stale_dirs+=("$seg_dir")
        fi
    done

    [[ ${#stale_dirs[@]} -eq 0 ]] && return 0

    for seg_dir in "${stale_dirs[@]}"; do
        local size_kb
        size_kb=$(get_path_size_kb "$seg_dir")
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$DRY_RUN" != "true" ]]; then
            if safe_remove "$seg_dir" true; then
                stale_count=$((stale_count + 1))
                stale_kb=$((stale_kb + size_kb))
            fi
        else
            stale_count=$((stale_count + 1))
            stale_kb=$((stale_kb + size_kb))
        fi
    done

    if [[ $stale_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$((stale_kb * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} NeatDM stale downloads · ${stale_count} items, $(colorize_human_size "$size_human") ${YELLOW}dry${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$stale_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} NeatDM stale downloads · ${stale_count} items, ${line_color}${size_human}${NC}"
        fi
        files_cleaned=$((files_cleaned + stale_count))
        total_size_cleaned=$((total_size_cleaned + stale_kb))
        total_items=$((total_items + 1))
        note_activity
    fi
}
# Gaming platforms.
clean_gaming_platforms() {
    safe_clean ~/Library/Caches/com.valvesoftware.steam/* "Steam cache"
    if [[ -d ~/Library/Application\ Support/Steam ]]; then
        safe_clean ~/Library/Application\ Support/Steam/htmlcache/* "Steam web cache"
        safe_clean ~/Library/Application\ Support/Steam/appcache/* "Steam app cache"
        safe_clean ~/Library/Application\ Support/Steam/depotcache/* "Steam depot cache"
        safe_clean ~/Library/Application\ Support/Steam/steamapps/shadercache/* "Steam shader cache"
        safe_clean ~/Library/Application\ Support/Steam/logs/* "Steam logs"
    fi
    safe_clean ~/Library/Caches/com.epicgames.EpicGamesLauncher/* "Epic Games cache"
    safe_clean ~/Library/Caches/com.blizzard.Battle.net/* "Battle.net cache"
    if [[ -d ~/Library/Application\ Support/Battle.net ]]; then
        safe_clean ~/Library/Application\ Support/Battle.net/Cache/* "Battle.net app cache"
    fi
    safe_clean ~/Library/Caches/com.ea.*/* "EA Origin cache"
    safe_clean ~/Library/Caches/com.gog.galaxy/* "GOG Galaxy cache"
    safe_clean ~/Library/Caches/com.riotgames.*/* "Riot Games cache"
    if [[ -d ~/Library/Application\ Support/minecraft ]]; then
        safe_clean ~/Library/Application\ Support/minecraft/logs/* "Minecraft logs"
        safe_clean ~/Library/Application\ Support/minecraft/crash-reports/* "Minecraft crash reports"
        safe_clean ~/Library/Application\ Support/minecraft/webcache/* "Minecraft web cache"
        safe_clean ~/Library/Application\ Support/minecraft/webcache2/* "Minecraft web cache 2"
    fi
    if [[ -d ~/.lunarclient ]]; then
        safe_clean ~/.lunarclient/game-cache/* "Lunar Client game cache"
        safe_clean ~/.lunarclient/launcher-cache/* "Lunar Client launcher cache"
        safe_clean ~/.lunarclient/logs/* "Lunar Client logs"
        safe_clean ~/.lunarclient/offline/*/logs/* "Lunar Client offline logs"
        safe_clean ~/.lunarclient/offline/files/*/logs/* "Lunar Client offline file logs"
    fi
    safe_clean ~/Library/Caches/net.pcsx2.PCSX2/* "PCSX2 cache"
    if [[ -d ~/Library/Application\ Support/PCSX2 ]]; then
        safe_clean ~/Library/Application\ Support/PCSX2/cache/* "PCSX2 shader cache"
        safe_clean ~/Library/Logs/PCSX2/* "PCSX2 logs"
    fi
    if [[ -d ~/Library/Application\ Support/rpcs3 ]]; then
        safe_clean ~/Library/Caches/net.rpcs3.rpcs3/* "RPCS3 cache"
        safe_clean ~/Library/Application\ Support/rpcs3/logs/* "RPCS3 logs"
    fi
}
# Translation/dictionary apps.
clean_translation_apps() {
    safe_clean ~/Library/Caches/com.youdao.YoudaoDict "Youdao Dictionary cache"
    safe_clean ~/Library/Caches/com.eudic.* "Eudict cache"
    safe_clean ~/Library/Caches/com.bob-build.Bob "Bob Translation cache"
}
# Screenshot/recording tools.
clean_screenshot_tools() {
    safe_clean ~/Library/Caches/com.cleanshot.* "CleanShot cache"
    safe_clean ~/Library/Caches/com.reincubate.camo "Camo cache"
    safe_clean ~/Library/Caches/com.xnipapp.xnip "Xnip cache"
}
# Email clients.
clean_email_clients() {
    safe_clean ~/Library/Caches/com.readdle.smartemail-Mac "Spark cache"
    safe_clean ~/Library/Caches/com.airmail.* "Airmail cache"
}
# Task management apps.
clean_task_apps() {
    safe_clean ~/Library/Caches/com.todoist.mac.Todoist "Todoist cache"
    safe_clean ~/Library/Caches/com.any.do.* "Any.do cache"
}
# Shell/terminal utilities.
clean_shell_utils() {
    safe_clean ~/.zcompdump* "Zsh completion cache"
    safe_clean ~/.lesshst "less history"
    safe_clean ~/.viminfo.tmp "Vim temporary files"
    safe_clean ~/.wget-hsts "wget HSTS cache"
    safe_clean ~/.cacher/logs/* "Cacher logs"
    safe_clean ~/.kite/logs/* "Kite logs"
    safe_clean ~/Library/Caches/dev.warp.Warp-Stable/* "Warp cache"
    safe_clean ~/Library/Logs/warp.log "Warp log"
    safe_clean ~/Library/Caches/SentryCrash/Warp/* "Warp Sentry crash reports"
    safe_clean ~/Library/Caches/com.mitchellh.ghostty/* "Ghostty cache"
}
# Input methods and system utilities.
clean_system_utils() {
    safe_clean ~/Library/Caches/com.runjuu.Input-Source-Pro/* "Input Source Pro cache"
    safe_clean ~/Library/Caches/macos-wakatime.WakaTime/* "WakaTime cache"
    # WeType input method (image and dict update cache, not engine or user dict)
    safe_clean ~/Library/Application\ Support/WeType/com.onevcat.Kingfisher.ImageCache.WeType/* "WeType image cache"
    safe_clean ~/Library/Application\ Support/WeType/DictUpdate/* "WeType dict update cache"
    # mihomo-party proxy tool (Electron)
    if [[ -d ~/Library/Application\ Support/mihomo-party ]]; then
        safe_clean ~/Library/Application\ Support/mihomo-party/Cache/* "mihomo-party cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/Code\ Cache/* "mihomo-party code cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/GPUCache/* "mihomo-party GPU cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/DawnGraphiteCache/* "mihomo-party Dawn cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/DawnWebGPUCache/* "mihomo-party WebGPU cache"
        safe_clean ~/Library/Application\ Support/mihomo-party/logs/* "mihomo-party logs"
    fi
    # Stash proxy tool
    safe_clean ~/Library/Caches/ws.stash.app.mac/* "Stash cache"
}
# Note-taking apps.
clean_note_apps() {
    safe_clean ~/Library/Caches/notion.id/* "Notion cache"
    safe_clean ~/Library/Caches/md.obsidian/* "Obsidian cache"
    safe_clean ~/Library/Caches/com.logseq.*/* "Logseq cache"
    safe_clean ~/Library/Caches/com.bear-writer.*/* "Bear cache"
    safe_clean ~/Library/Caches/com.evernote.*/* "Evernote cache"
    safe_clean ~/Library/Caches/com.yinxiang.*/* "Yinxiang Note cache"
}
# Launchers and automation tools.
clean_launcher_apps() {
    safe_clean ~/Library/Caches/com.runningwithcrayons.Alfred/* "Alfred cache"
    safe_clean ~/Library/Caches/cx.c3.theunarchiver/* "The Unarchiver cache"
}
# Remote desktop tools.
clean_remote_desktop() {
    safe_clean ~/Library/Caches/com.teamviewer.*/* "TeamViewer cache"
    safe_clean ~/Library/Caches/com.anydesk.*/* "AnyDesk cache"
    safe_clean ~/Library/Caches/com.todesk.*/* "ToDesk cache"
    safe_clean ~/Library/Caches/com.sunlogin.*/* "Sunlogin cache"
}
# Main entry for GUI app cleanup.
clean_user_gui_applications() {
    stop_section_spinner
    clean_communication_apps
    clean_dingtalk
    clean_ai_apps
    clean_design_tools
    clean_video_tools
    clean_3d_tools
    clean_productivity_apps
    clean_media_players
    clean_video_players
    clean_download_managers
    clean_gaming_platforms
    clean_translation_apps
    clean_screenshot_tools
    clean_email_clients
    clean_task_apps
    clean_shell_utils
    clean_system_utils
    clean_note_apps
    clean_launcher_apps
    clean_remote_desktop
}
