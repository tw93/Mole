#!/bin/bash
# User GUI Applications Cleanup Module (desktop apps, media, utilities).
set -euo pipefail
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
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Simulator is running, skipping Simulator cache/temp/log cleanup"
    fi
    safe_clean ~/Library/Caches/com.apple.dt.Xcode/* "Xcode cache"
    safe_clean ~/Library/Developer/Xcode/iOS\ Device\ Logs/* "iOS device logs"
    safe_clean ~/Library/Developer/Xcode/watchOS\ Device\ Logs/* "watchOS device logs"
    safe_clean ~/Library/Developer/Xcode/Products/* "Xcode build products"
    if [[ "$xcode_running" == "false" ]]; then
        safe_clean ~/Library/Developer/Xcode/DerivedData/* "Xcode derived data"
        safe_clean ~/Library/Developer/Xcode/Archives/* "Xcode archives"
        safe_clean ~/Library/Developer/Xcode/DocumentationCache/* "Xcode documentation cache"
        safe_clean ~/Library/Developer/Xcode/DocumentationIndex/* "Xcode documentation index"
    else
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode is running, skipping DerivedData/Archives/Documentation cleanup"
    fi
}
# Code editors.
clean_code_editors() {
    safe_clean ~/Library/Application\ Support/Code/logs/* "VS Code logs"
    safe_clean ~/Library/Application\ Support/Code/Cache/* "VS Code cache"
    safe_clean ~/Library/Application\ Support/Code/CachedExtensions/* "VS Code extension cache"
    safe_clean ~/Library/Application\ Support/Code/CachedData/* "VS Code data cache"
    safe_clean ~/Library/Caches/com.sublimetext.*/* "Sublime Text cache"
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
    safe_clean ~/Library/Application\ Support/Microsoft/Teams/Cache/* "Microsoft Teams legacy cache"
    safe_clean ~/Library/Application\ Support/Microsoft/Teams/Application\ Cache/* "Microsoft Teams legacy application cache"
    safe_clean ~/Library/Application\ Support/Microsoft/Teams/Code\ Cache/* "Microsoft Teams legacy code cache"
    safe_clean ~/Library/Application\ Support/Microsoft/Teams/GPUCache/* "Microsoft Teams legacy GPU cache"
    safe_clean ~/Library/Application\ Support/Microsoft/Teams/logs/* "Microsoft Teams legacy logs"
    safe_clean ~/Library/Application\ Support/Microsoft/Teams/tmp/* "Microsoft Teams legacy temp files"
}
# DingTalk.
clean_dingtalk() {
    safe_clean ~/Library/Caches/dd.work.exclusive4aliding/* "DingTalk iDingTalk cache"
    safe_clean ~/Library/Caches/com.alibaba.AliLang.osx/* "AliLang security component"
    safe_clean ~/Library/Application\ Support/iDingTalk/log/* "DingTalk logs"
    safe_clean ~/Library/Application\ Support/iDingTalk/holmeslogs/* "DingTalk holmes logs"
}
# AI assistants.
clean_ai_apps() {
    safe_clean ~/Library/Caches/com.openai.chat/* "ChatGPT cache"
    safe_clean ~/Library/Caches/com.anthropic.claudefordesktop/* "Claude desktop cache"
    safe_clean ~/Library/Logs/Claude/* "Claude logs"
}
# Design and creative tools.
clean_design_tools() {
    safe_clean ~/Library/Caches/com.bohemiancoding.sketch3/* "Sketch cache"
    safe_clean ~/Library/Application\ Support/com.bohemiancoding.sketch3/cache/* "Sketch app cache"
    safe_clean ~/Library/Caches/Adobe/* "Adobe cache"
    safe_clean ~/Library/Caches/com.adobe.*/* "Adobe app caches"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Figma cache"
    safe_clean ~/Library/Application\ Support/Adobe/Common/Media\ Cache\ Files/* "Adobe media cache files"
    # Raycast cache is protected (clipboard history, images).
}
# Video editing tools.
clean_video_tools() {
    safe_clean ~/Library/Caches/net.telestream.screenflow10/* "ScreenFlow cache"
    safe_clean ~/Library/Caches/com.apple.FinalCut/* "Final Cut Pro cache"
    safe_clean ~/Library/Caches/com.blackmagic-design.DaVinciResolve/* "DaVinci Resolve cache"
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
    safe_clean ~/Library/Caches/tv.danmaku.bili/* "Bilibili cache"
    safe_clean ~/Library/Caches/com.douyu.*/* "Douyu cache"
    safe_clean ~/Library/Caches/com.huya.*/* "Huya cache"
}
# Download managers.
clean_download_managers() {
    safe_clean ~/Library/Caches/net.xmac.aria2gui "Aria2 cache"
    safe_clean ~/Library/Caches/org.m0k.transmission "Transmission cache"
    safe_clean ~/Library/Caches/com.qbittorrent.qBittorrent "qBittorrent cache"
    safe_clean ~/Library/Caches/com.downie.Downie-* "Downie cache"
    safe_clean ~/Library/Caches/com.folx.*/* "Folx cache"
    safe_clean ~/Library/Caches/com.charlessoft.pacifist/* "Pacifist cache"
}
# Gaming platforms.
clean_gaming_platforms() {
    safe_clean ~/Library/Caches/com.valvesoftware.steam/* "Steam cache"
    safe_clean ~/Library/Application\ Support/Steam/htmlcache/* "Steam web cache"
    safe_clean ~/Library/Application\ Support/Steam/appcache/* "Steam app cache"
    safe_clean ~/Library/Application\ Support/Steam/depotcache/* "Steam depot cache"
    safe_clean ~/Library/Application\ Support/Steam/steamapps/shadercache/* "Steam shader cache"
    safe_clean ~/Library/Application\ Support/Steam/logs/* "Steam logs"
    safe_clean ~/Library/Caches/com.epicgames.EpicGamesLauncher/* "Epic Games cache"
    safe_clean ~/Library/Caches/com.blizzard.Battle.net/* "Battle.net cache"
    safe_clean ~/Library/Application\ Support/Battle.net/Cache/* "Battle.net app cache"
    safe_clean ~/Library/Caches/com.ea.*/* "EA Origin cache"
    safe_clean ~/Library/Caches/com.gog.galaxy/* "GOG Galaxy cache"
    safe_clean ~/Library/Caches/com.riotgames.*/* "Riot Games cache"
    safe_clean ~/Library/Application\ Support/minecraft/logs/* "Minecraft logs"
    safe_clean ~/Library/Application\ Support/minecraft/crash-reports/* "Minecraft crash reports"
    safe_clean ~/Library/Application\ Support/minecraft/webcache/* "Minecraft web cache"
    safe_clean ~/Library/Application\ Support/minecraft/webcache2/* "Minecraft web cache 2"
    safe_clean ~/.lunarclient/game-cache/* "Lunar Client game cache"
    safe_clean ~/.lunarclient/launcher-cache/* "Lunar Client launcher cache"
    safe_clean ~/.lunarclient/logs/* "Lunar Client logs"
    safe_clean ~/.lunarclient/offline/*/logs/* "Lunar Client offline logs"
    safe_clean ~/.lunarclient/offline/files/*/logs/* "Lunar Client offline file logs"
    safe_clean ~/Library/Caches/net.pcsx2.PCSX2/* "PCSX2 cache"
    safe_clean ~/Library/Application\ Support/PCSX2/cache/* "PCSX2 shader cache"
    safe_clean ~/Library/Logs/PCSX2/* "PCSX2 logs"
    safe_clean ~/Library/Caches/net.rpcs3.rpcs3/* "RPCS3 cache"
    safe_clean ~/Library/Application\ Support/rpcs3/logs/* "RPCS3 logs"
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
}
# Input methods and system utilities.
clean_system_utils() {
    safe_clean ~/Library/Caches/com.runjuu.Input-Source-Pro/* "Input Source Pro cache"
    safe_clean ~/Library/Caches/macos-wakatime.WakaTime/* "WakaTime cache"
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
