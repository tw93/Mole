#!/bin/bash
# Mole - Application Protection
# System critical and data-protected application lists

set -euo pipefail

if [[ -n "${MOLE_APP_PROTECTION_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_APP_PROTECTION_LOADED=1

_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "${MOLE_BASE_LOADED:-}" ]] && source "$_MOLE_CORE_DIR/base.sh"

# Application Management

# Critical system components protected from uninstallation
readonly SYSTEM_CRITICAL_BUNDLES=(
    "com.apple.*" # System essentials
    "loginwindow"
    "dock"
    "systempreferences"
    "finder"
    "safari"
    "com.apple.Settings*"
    "com.apple.SystemSettings*"
    "com.apple.controlcenter*"
    "com.apple.backgroundtaskmanagement*"
    "com.apple.loginitems*"
    "com.apple.sharedfilelist*"
    "com.apple.sfl*"
    "backgroundtaskmanagementagent"
    "keychain*"
    "security*"
    "bluetooth*"
    "wifi*"
    "network*"
    "tcc"
    "notification*"
    "accessibility*"
    "universalaccess*"
    "HIToolbox*"
    "textinput*"
    "TextInput*"
    "keyboard*"
    "Keyboard*"
    "inputsource*"
    "InputSource*"
    "keylayout*"
    "KeyLayout*"
    "GlobalPreferences"
    ".GlobalPreferences"
    "com.apple.inputmethod.*"
    "org.pqrs.Karabiner*"
    "com.apple.inputsource*"
    "com.apple.TextInputMenuAgent"
    "com.apple.TextInputSwitcher"
)

# Applications with sensitive data; protected during cleanup but removable
readonly DATA_PROTECTED_BUNDLES=(
    # Input Methods (protected during cleanup, uninstall allowed)
    "com.tencent.inputmethod.QQInput"
    "com.sogou.inputmethod.*"
    "com.baidu.inputmethod.*"
    "com.googlecode.rimeime.*"
    "im.rime.*"
    "*.inputmethod"
    "*.InputMethod"
    "*IME"

    # System Utilities & Cleanup Tools
    "com.nektony.*"                 # App Cleaner & Uninstaller
    "com.macpaw.*"                  # CleanMyMac, CleanMaster
    "com.freemacsoft.AppCleaner"    # AppCleaner
    "com.omnigroup.omnidisksweeper" # OmniDiskSweeper
    "com.daisydiskapp.*"            # DaisyDisk
    "com.tunabellysoftware.*"       # Disk Utility apps
    "com.grandperspectiv.*"         # GrandPerspective
    "com.binaryfruit.*"             # FusionCast

    # Password Managers & Security
    "com.1password.*" # 1Password
    "com.agilebits.*" # 1Password legacy
    "com.lastpass.*"  # LastPass
    "com.dashlane.*"  # Dashlane
    "com.bitwarden.*" # Bitwarden
    "com.keepassx.*"  # KeePassXC
    "org.keepassx.*"  # KeePassX
    "com.authy.*"     # Authy
    "com.yubico.*"    # YubiKey Manager

    # Development Tools - IDEs & Editors
    "com.jetbrains.*"              # JetBrains IDEs (IntelliJ, DataGrip, etc.)
    "JetBrains*"                   # JetBrains Application Support folders
    "com.microsoft.VSCode"         # Visual Studio Code
    "com.visualstudio.code.*"      # VS Code variants
    "com.sublimetext.*"            # Sublime Text
    "com.sublimehq.*"              # Sublime Merge
    "com.microsoft.VSCodeInsiders" # VS Code Insiders
    "com.apple.dt.Xcode"           # Xcode (keep settings)
    "com.coteditor.CotEditor"      # CotEditor
    "com.macromates.TextMate"      # TextMate
    "com.panic.Nova"               # Nova
    "abnerworks.Typora"            # Typora (Markdown editor)
    "com.uranusjr.macdown"         # MacDown

    # AI & LLM Tools
    "com.todesktop.*"             # Cursor (often uses generic todesktop ID)
    "Cursor"                      # Cursor App Support
    "com.anthropic.claude*"       # Claude
    "Claude"                      # Claude App Support
    "com.openai.chat*"            # ChatGPT
    "ChatGPT"                     # ChatGPT App Support
    "com.ollama.ollama"           # Ollama
    "Ollama"                      # Ollama App Support
    "com.lmstudio.lmstudio"       # LM Studio
    "LM Studio"                   # LM Studio App Support
    "co.supertool.chatbox"        # Chatbox
    "page.jan.jan"                # Jan
    "com.huggingface.huggingchat" # HuggingChat
    "Gemini"                      # Gemini
    "com.perplexity.Perplexity"   # Perplexity
    "com.drawthings.DrawThings"   # Draw Things
    "com.divamgupta.diffusionbee" # DiffusionBee
    "com.exafunction.windsurf"    # Windsurf
    "com.quora.poe.electron"      # Poe
    "chat.openai.com.*"           # OpenAI web wrappers

    # Development Tools - Database Clients
    "com.sequelpro.*"                   # Sequel Pro
    "com.sequel-ace.*"                  # Sequel Ace
    "com.tinyapp.*"                     # TablePlus
    "com.dbeaver.*"                     # DBeaver
    "com.navicat.*"                     # Navicat
    "com.mongodb.compass"               # MongoDB Compass
    "com.redis.RedisInsight"            # Redis Insight
    "com.pgadmin.pgadmin4"              # pgAdmin
    "com.eggerapps.Sequel-Pro"          # Sequel Pro legacy
    "com.valentina-db.Valentina-Studio" # Valentina Studio
    "com.dbvis.DbVisualizer"            # DbVisualizer

    # Development Tools - API & Network
    "com.postmanlabs.mac"      # Postman
    "com.konghq.insomnia"      # Insomnia
    "com.CharlesProxy.*"       # Charles Proxy
    "com.proxyman.*"           # Proxyman
    "com.getpaw.*"             # Paw
    "com.luckymarmot.Paw"      # Paw legacy
    "com.charlesproxy.charles" # Charles
    "com.telerik.Fiddler"      # Fiddler
    "com.usebruno.app"         # Bruno (API client)

    # Network Proxy & VPN Tools (pattern-based protection)
    # Clash variants
    "*clash*"               # All Clash variants (ClashX, ClashX Pro, Clash Verge, etc)
    "*Clash*"               # Capitalized variants
    "com.nssurge.surge-mac" # Surge
    "*surge*"               # Surge variants
    "*Surge*"               # Surge variants
    "mihomo*"               # Mihomo Party and variants
    "*openvpn*"             # OpenVPN Connect and variants
    "*OpenVPN*"             # OpenVPN capitalized variants
    "net.openvpn.*"         # OpenVPN bundle IDs

    # Proxy Clients (Shadowsocks, V2Ray, etc)
    "*ShadowsocksX-NG*" # ShadowsocksX-NG
    "com.qiuyuzhou.*"   # ShadowsocksX-NG bundle
    "*v2ray*"           # V2Ray variants
    "*V2Ray*"           # V2Ray variants
    "*v2box*"           # V2Box
    "*V2Box*"           # V2Box
    "*nekoray*"         # Nekoray
    "*sing-box*"        # Sing-box
    "*OneBox*"          # OneBox
    "*hiddify*"         # Hiddify
    "*Hiddify*"         # Hiddify
    "*loon*"            # Loon
    "*Loon*"            # Loon
    "*quantumult*"      # Quantumult X

    # Mesh & Corporate VPNs
    "*tailscale*"       # Tailscale
    "io.tailscale.*"    # Tailscale bundle
    "*zerotier*"        # ZeroTier
    "com.zerotier.*"    # ZeroTier bundle
    "*1dot1dot1dot1*"   # Cloudflare WARP
    "*cloudflare*warp*" # Cloudflare WARP

    # Commercial VPNs
    "*nordvpn*"               # NordVPN
    "*expressvpn*"            # ExpressVPN
    "*protonvpn*"             # ProtonVPN
    "*surfshark*"             # Surfshark
    "*windscribe*"            # Windscribe
    "*mullvad*"               # Mullvad
    "*privateinternetaccess*" # PIA

    # Screensaver & Dynamic Wallpaper
    "*Aerial*" # Aerial screensaver (all case variants)
    "*aerial*" # Aerial lowercase
    "*Fliqlo*" # Fliqlo screensaver (all case variants)
    "*fliqlo*" # Fliqlo lowercase

    # Development Tools - Git & Version Control
    "com.github.GitHubDesktop"       # GitHub Desktop
    "com.sublimemerge"               # Sublime Merge
    "com.torusknot.SourceTreeNotMAS" # SourceTree
    "com.git-tower.Tower*"           # Tower
    "com.gitfox.GitFox"              # GitFox
    "com.github.Gitify"              # Gitify
    "com.fork.Fork"                  # Fork
    "com.axosoft.gitkraken"          # GitKraken

    # Development Tools - Terminal & Shell
    "com.googlecode.iterm2"  # iTerm2
    "net.kovidgoyal.kitty"   # Kitty
    "io.alacritty"           # Alacritty
    "com.github.wez.wezterm" # WezTerm
    "com.hyper.Hyper"        # Hyper
    "com.mizage.divvy"       # Divvy
    "com.fig.Fig"            # Fig (terminal assistant)
    "dev.warp.Warp-Stable"   # Warp
    "com.termius-dmg"        # Termius (SSH client)

    # Development Tools - Docker & Virtualization
    "com.docker.docker"             # Docker Desktop
    "com.getutm.UTM"                # UTM
    "com.vmware.fusion"             # VMware Fusion
    "com.parallels.desktop.*"       # Parallels Desktop
    "org.virtualbox.app.VirtualBox" # VirtualBox
    "com.vagrant.*"                 # Vagrant
    "com.orbstack.OrbStack"         # OrbStack

    # System Monitoring & Performance
    "com.bjango.istatmenus*"       # iStat Menus
    "eu.exelban.Stats"             # Stats
    "com.monitorcontrol.*"         # MonitorControl
    "com.bresink.system-toolkit.*" # TinkerTool System
    "com.mediaatelier.MenuMeters"  # MenuMeters
    "com.activity-indicator.app"   # Activity Indicator
    "net.cindori.sensei"           # Sensei

    # Window Management & Productivity
    "com.macitbetter.*"            # BetterTouchTool, BetterSnapTool
    "com.hegenberg.*"              # BetterTouchTool legacy
    "com.manytricks.*"             # Moom, Witch, Name Mangler, Resolutionator
    "com.divisiblebyzero.*"        # Spectacle
    "com.koingdev.*"               # Koingg apps
    "com.if.Amphetamine"           # Amphetamine
    "com.lwouis.alt-tab-macos"     # AltTab
    "net.matthewpalmer.Vanilla"    # Vanilla
    "com.lightheadsw.Caffeine"     # Caffeine
    "com.contextual.Contexts"      # Contexts
    "com.amethyst.Amethyst"        # Amethyst
    "com.knollsoft.Rectangle"      # Rectangle
    "com.knollsoft.Hookshot"       # Hookshot
    "com.surteesstudios.Bartender" # Bartender
    "com.gaosun.eul"               # eul (system monitor)
    "com.pointum.hazeover"         # HazeOver

    # Launcher & Automation
    "com.runningwithcrayons.Alfred"   # Alfred
    "com.raycast.macos"               # Raycast
    "com.blacktree.Quicksilver"       # Quicksilver
    "com.stairways.keyboardmaestro.*" # Keyboard Maestro
    "com.manytricks.Butler"           # Butler
    "com.happenapps.Quitter"          # Quitter
    "com.pilotmoon.scroll-reverser"   # Scroll Reverser
    "org.pqrs.Karabiner-Elements"     # Karabiner-Elements
    "com.apple.Automator"             # Automator (system, but keep user workflows)

    # Note-Taking & Documentation
    "com.bear-writer.*"           # Bear
    "com.typora.*"                # Typora
    "com.ulyssesapp.*"            # Ulysses
    "com.literatureandlatte.*"    # Scrivener
    "com.dayoneapp.*"             # Day One
    "notion.id"                   # Notion
    "md.obsidian"                 # Obsidian
    "com.logseq.logseq"           # Logseq
    "com.evernote.Evernote"       # Evernote
    "com.onenote.mac"             # OneNote
    "com.omnigroup.OmniOutliner*" # OmniOutliner
    "net.shinyfrog.bear"          # Bear legacy
    "com.goodnotes.GoodNotes"     # GoodNotes
    "com.marginnote.MarginNote*"  # MarginNote
    "com.roamresearch.*"          # Roam Research
    "com.reflect.ReflectApp"      # Reflect
    "com.inkdrop.*"               # Inkdrop

    # Design & Creative Tools
    "com.adobe.*"             # Adobe Creative Suite
    "com.bohemiancoding.*"    # Sketch
    "com.figma.*"             # Figma
    "com.framerx.*"           # Framer
    "com.zeplin.*"            # Zeplin
    "com.invisionapp.*"       # InVision
    "com.principle.*"         # Principle
    "com.pixelmatorteam.*"    # Pixelmator
    "com.affinitydesigner.*"  # Affinity Designer
    "com.affinityphoto.*"     # Affinity Photo
    "com.affinitypublisher.*" # Affinity Publisher
    "com.linearity.curve"     # Linearity Curve
    "com.canva.CanvaDesktop"  # Canva
    "com.maxon.cinema4d"      # Cinema 4D
    "com.autodesk.*"          # Autodesk products
    "com.sketchup.*"          # SketchUp

    # Communication & Collaboration
    "com.tencent.xinWeChat"                   # WeChat (Chinese users)
    "com.tencent.qq"                          # QQ
    "com.alibaba.DingTalkMac"                 # DingTalk
    "com.alibaba.AliLang.osx"                 # AliLang (retain login/config data)
    "com.alibaba.alilang3.osx.ShipIt"         # AliLang updater component
    "com.alibaba.AlilangMgr.QueryNetworkInfo" # AliLang network helper
    "us.zoom.xos"                             # Zoom
    "com.microsoft.teams*"                    # Microsoft Teams
    "com.slack.Slack"                         # Slack
    "com.hnc.Discord"                         # Discord
    "app.legcord.Legcord"                     # Legcord
    "org.telegram.desktop"                    # Telegram
    "ru.keepcoder.Telegram"                   # Telegram legacy
    "net.whatsapp.WhatsApp"                   # WhatsApp
    "com.skype.skype"                         # Skype
    "com.cisco.webexmeetings"                 # Webex
    "com.ringcentral.RingCentral"             # RingCentral
    "com.readdle.smartemail-Mac"              # Spark Email
    "com.airmail.*"                           # Airmail
    "com.postbox-inc.postbox"                 # Postbox
    "com.tinyspeck.slackmacgap"               # Slack legacy

    # Task Management & Productivity
    "com.omnigroup.OmniFocus*" # OmniFocus
    "com.culturedcode.*"       # Things
    "com.todoist.*"            # Todoist
    "com.any.do.*"             # Any.do
    "com.ticktick.*"           # TickTick
    "com.microsoft.to-do"      # Microsoft To Do
    "com.trello.trello"        # Trello
    "com.asana.nativeapp"      # Asana
    "com.clickup.*"            # ClickUp
    "com.monday.desktop"       # Monday.com
    "com.airtable.airtable"    # Airtable
    "com.notion.id"            # Notion (also note-taking)
    "com.linear.linear"        # Linear

    # File Transfer & Sync
    "com.panic.transmit*"            # Transmit (FTP/SFTP)
    "com.binarynights.ForkLift*"     # ForkLift
    "com.noodlesoft.Hazel"           # Hazel
    "com.cyberduck.Cyberduck"        # Cyberduck
    "io.filezilla.FileZilla"         # FileZilla
    "com.apple.Xcode.CloudDocuments" # Xcode Cloud Documents
    "com.synology.*"                 # Synology apps

    # Cloud Storage & Backup (Issue #204)
    "com.dropbox.*"              # Dropbox
    "com.getdropbox.*"           # Dropbox legacy
    "*dropbox*"                  # Dropbox helpers/updaters
    "ws.agile.*"                 # 1Password sync helpers
    "com.backblaze.*"            # Backblaze
    "*backblaze*"                # Backblaze helpers
    "com.box.desktop*"           # Box
    "*box.desktop*"              # Box helpers
    "com.microsoft.OneDrive*"    # Microsoft OneDrive
    "com.microsoft.SyncReporter" # OneDrive sync reporter
    "*OneDrive*"                 # OneDrive helpers/updaters
    "com.google.GoogleDrive"     # Google Drive
    "com.google.keystone*"       # Google updaters (Drive, Chrome, etc.)
    "*GoogleDrive*"              # Google Drive helpers
    "com.amazon.drive"           # Amazon Drive
    "com.apple.bird"             # iCloud Drive daemon
    "com.apple.CloudDocs*"       # iCloud Documents
    "com.displaylink.*"          # DisplayLink
    "com.fujitsu.pfu.ScanSnap*"  # ScanSnap
    "com.citrix.*"               # Citrix Workspace
    "org.xquartz.*"              # XQuartz
    "us.zoom.updater*"           # Zoom updaters
    "com.DigiDNA.iMazing*"       # iMazing
    "com.shirtpocket.*"          # SuperDuper backup
    "homebrew.mxcl.*"            # Homebrew services

    # Screenshot & Recording
    "com.cleanshot.*"                   # CleanShot X
    "com.xnipapp.xnip"                  # Xnip
    "com.reincubate.camo"               # Camo
    "com.tunabellysoftware.ScreenFloat" # ScreenFloat
    "net.telestream.screenflow*"        # ScreenFlow
    "com.techsmith.snagit*"             # Snagit
    "com.techsmith.camtasia*"           # Camtasia
    "com.obsidianapp.screenrecorder"    # Screen Recorder
    "com.kap.Kap"                       # Kap
    "com.getkap.*"                      # Kap legacy
    "com.linebreak.CloudApp"            # CloudApp
    "com.droplr.droplr-mac"             # Droplr

    # Media & Entertainment
    "com.spotify.client"       # Spotify
    "com.apple.Music"          # Apple Music
    "com.apple.podcasts"       # Apple Podcasts
    "com.apple.BKAgentService" # Apple Books (Agent)
    "com.apple.iBooksX"        # Apple Books
    "com.apple.iBooks"         # Apple Books (Legacy)
    "com.apple.FinalCutPro"    # Final Cut Pro
    "com.apple.Motion"         # Motion
    "com.apple.Compressor"     # Compressor
    "com.blackmagic-design.*"  # DaVinci Resolve
    "com.colliderli.iina"      # IINA
    "org.videolan.vlc"         # VLC
    "io.mpv"                   # MPV
    "com.noodlesoft.Hazel"     # Hazel (automation)
    "tv.plex.player.desktop"   # Plex
    "com.netease.163music"     # NetEase Music

    # License Management & App Stores
    "com.paddle.Paddle*"          # Paddle (license management)
    "com.setapp.DesktopClient"    # Setapp
    "com.devmate.*"               # DevMate (license framework)
    "org.sparkle-project.Sparkle" # Sparkle (update framework)
)

# Centralized check for critical system components (case-insensitive)
is_critical_system_component() {
    local token="$1"
    [[ -z "$token" ]] && return 1

    local lower
    lower=$(echo "$token" | LC_ALL=C tr '[:upper:]' '[:lower:]')

    case "$lower" in
        *backgroundtaskmanagement* | *loginitems* | *systempreferences* | *systemsettings* | *settings* | *preferences* | *controlcenter* | *biometrickit* | *sfl* | *tcc*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Legacy function - preserved for backward compatibility
# Use should_protect_from_uninstall() or should_protect_data() instead
readonly PRESERVED_BUNDLE_PATTERNS=("${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}")

# Check if bundle ID matches pattern (glob support)
bundle_matches_pattern() {
    local bundle_id="$1"
    local pattern="$2"

    [[ -z "$pattern" ]] && return 1

    # Use bash [[  ]] for glob pattern matching (works with variables in bash 3.2+)
    # shellcheck disable=SC2053  # allow glob pattern matching
    if [[ "$bundle_id" == $pattern ]]; then
        return 0
    fi
    return 1
}

# Check if application is a protected system component
should_protect_from_uninstall() {
    local bundle_id="$1"
    for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}"; do
        if bundle_matches_pattern "$bundle_id" "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Check if application data should be protected during cleanup
should_protect_data() {
    local bundle_id="$1"
    # Protect both system critical and data protected bundles during cleanup
    for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}"; do
        if bundle_matches_pattern "$bundle_id" "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Check if a path is protected from deletion
# Centralized logic to protect system settings, control center, and critical apps
#
# Args: $1 - path to check
# Returns: 0 if protected, 1 if safe to delete
should_protect_path() {
    local path="$1"
    [[ -z "$path" ]] && return 1

    local path_lower
    path_lower=$(echo "$path" | LC_ALL=C tr '[:upper:]' '[:lower:]')

    # 1. Keyword-based matching for system components
    # Protect System Settings, Preferences, Control Center, and related XPC services
    # Also protect "Settings" (used in macOS Sequoia) and savedState files
    if [[ "$path_lower" =~ systemsettings || "$path_lower" =~ systempreferences || "$path_lower" =~ controlcenter ]]; then
        return 0
    fi

    # Additional check for com.apple.Settings (macOS Sequoia System Settings)
    if [[ "$path_lower" =~ com\.apple\.settings ]]; then
        return 0
    fi

    # Protect Notes cache (search index issues)
    if [[ "$path_lower" =~ com\.apple\.notes ]]; then
        return 0
    fi

    # 2. Protect caches critical for system UI rendering
    # These caches are essential for modern macOS (Sonoma/Sequoia) system UI rendering
    case "$path" in
        # System Settings and Control Center caches (CRITICAL - prevents blank panel bug)
        *com.apple.systempreferences.cache* | *com.apple.Settings.cache* | *com.apple.controlcenter.cache*)
            return 0
            ;;
        # Finder and Dock (system essential)
        *com.apple.finder.cache* | *com.apple.dock.cache*)
            return 0
            ;;
        # System XPC services and sandboxed containers
        */Library/Containers/com.apple.Settings* | */Library/Containers/com.apple.SystemSettings* | */Library/Containers/com.apple.controlcenter*)
            return 0
            ;;
        */Library/Group\ Containers/com.apple.systempreferences* | */Library/Group\ Containers/com.apple.Settings*)
            return 0
            ;;
        # Shared file lists for System Settings (macOS Sequoia) - Issue #136
        */com.apple.sharedfilelist/*com.apple.Settings* | */com.apple.sharedfilelist/*com.apple.SystemSettings* | */com.apple.sharedfilelist/*systempreferences*)
            return 0
            ;;
    esac

    # 3. Extract bundle ID from sandbox paths
    # Matches: .../Library/Containers/bundle.id/...
    # Matches: .../Library/Group Containers/group.id/...
    if [[ "$path" =~ /Library/Containers/([^/]+) ]] || [[ "$path" =~ /Library/Group\ Containers/([^/]+) ]]; then
        local bundle_id="${BASH_REMATCH[1]}"
        if should_protect_data "$bundle_id"; then
            return 0
        fi
    fi

    # 4. Check for specific hardcoded critical patterns
    case "$path" in
        *com.apple.Settings* | *com.apple.SystemSettings* | *com.apple.controlcenter* | *com.apple.finder* | *com.apple.dock*)
            return 0
            ;;
    esac

    # 5. Protect critical preference files and user data
    case "$path" in
        */Library/Preferences/com.apple.dock.plist | */Library/Preferences/com.apple.finder.plist)
            return 0
            ;;
        # Bluetooth and WiFi configurations
        */ByHost/com.apple.bluetooth.* | */ByHost/com.apple.wifi.*)
            return 0
            ;;
        # iCloud Drive - protect user's cloud synced data
        */Library/Mobile\ Documents* | */Mobile\ Documents*)
            return 0
            ;;
    esac

    # 6. Match full path against protected patterns
    # This catches things like /Users/tw93/Library/Caches/Claude when pattern is *Claude*
    for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}"; do
        if bundle_matches_pattern "$path" "$pattern"; then
            return 0
        fi
    done

    # 7. Check if the filename itself matches any protected patterns
    local filename
    filename=$(basename "$path")
    if should_protect_data "$filename"; then
        return 0
    fi

    return 1
}

# Check if a path is protected by whitelist patterns
# Args: $1 - path to check
# Returns: 0 if whitelisted, 1 if not
is_path_whitelisted() {
    local target_path="$1"
    [[ -z "$target_path" ]] && return 1

    # Normalize path (remove trailing slash)
    local normalized_target="${target_path%/}"

    # Empty whitelist means nothing is protected
    [[ ${#WHITELIST_PATTERNS[@]} -eq 0 ]] && return 1

    for pattern in "${WHITELIST_PATTERNS[@]}"; do
        # Pattern is already expanded/normalized in bin/clean.sh
        local check_pattern="${pattern%/}"
        local has_glob="false"
        case "$check_pattern" in
            *\** | *\?* | *\[*)
                has_glob="true"
                ;;
        esac

        # Check for exact match or glob pattern match
        # shellcheck disable=SC2053
        if [[ "$normalized_target" == "$check_pattern" ]] ||
            [[ "$normalized_target" == $check_pattern ]]; then
            return 0
        fi

        # Check if target is a parent directory of a whitelisted path
        # e.g., if pattern is /path/to/dir/subdir and target is /path/to/dir,
        # the target should be protected to preserve its whitelisted children
        if [[ "$check_pattern" == "$normalized_target"/* ]]; then
            return 0
        fi

        # Check if target is a child of a whitelisted directory path
        if [[ "$has_glob" == "false" && "$normalized_target" == "$check_pattern"/* ]]; then
            return 0
        fi
    done

    return 1
}

# Locate files associated with an application
find_app_files() {
    local bundle_id="$1"
    local app_name="$2"
    local -a files_to_clean=()

    # Normalize app name for matching
    local nospace_name="${app_name// /}"
    local underscore_name="${app_name// /_}"

    # Standard path patterns for user-level files
    local -a user_patterns=(
        "$HOME/Library/Application Support/$app_name"
        "$HOME/Library/Application Support/$bundle_id"
        "$HOME/Library/Caches/$bundle_id"
        "$HOME/Library/Caches/$app_name"
        "$HOME/Library/Logs/$app_name"
        "$HOME/Library/Logs/$bundle_id"
        "$HOME/Library/Application Support/CrashReporter/$app_name"
        "$HOME/Library/Saved Application State/$bundle_id.savedState"
        "$HOME/Library/Containers/$bundle_id"
        "$HOME/Library/WebKit/$bundle_id"
        "$HOME/Library/WebKit/com.apple.WebKit.WebContent/$bundle_id"
        "$HOME/Library/HTTPStorages/$bundle_id"
        "$HOME/Library/Cookies/$bundle_id.binarycookies"
        "$HOME/Library/LaunchAgents/$bundle_id.plist"
        "$HOME/Library/Application Scripts/$bundle_id"
        "$HOME/Library/Services/$app_name.workflow"
        "$HOME/Library/QuickLook/$app_name.qlgenerator"
        "$HOME/Library/Internet Plug-Ins/$app_name.plugin"
        "$HOME/Library/Audio/Plug-Ins/Components/$app_name.component"
        "$HOME/Library/Audio/Plug-Ins/VST/$app_name.vst"
        "$HOME/Library/Audio/Plug-Ins/VST3/$app_name.vst3"
        "$HOME/Library/Audio/Plug-Ins/Digidesign/$app_name.dpm"
        "$HOME/Library/PreferencePanes/$app_name.prefPane"
        "$HOME/Library/Input Methods/$app_name.app"
        "$HOME/Library/Input Methods/$bundle_id.app"
        "$HOME/Library/Screen Savers/$app_name.saver"
        "$HOME/Library/Frameworks/$app_name.framework"
        "$HOME/Library/Autosave Information/$bundle_id"
        "$HOME/Library/Contextual Menu Items/$app_name.plugin"
        "$HOME/Library/Spotlight/$app_name.mdimporter"
        "$HOME/Library/ColorPickers/$app_name.colorPicker"
        "$HOME/Library/Workflows/$app_name.workflow"
        "$HOME/.config/$app_name"
        "$HOME/.local/share/$app_name"
        "$HOME/.$app_name"
        "$HOME/.$app_name"rc
    )

    # Add sanitized name variants if unique enough
    if [[ ${#app_name} -gt 3 && "$app_name" =~ [[:space:]] ]]; then
        user_patterns+=(
            "$HOME/Library/Application Support/$nospace_name"
            "$HOME/Library/Caches/$nospace_name"
            "$HOME/Library/Logs/$nospace_name"
            "$HOME/Library/Application Support/$underscore_name"
        )
    fi

    # Process standard patterns
    for p in "${user_patterns[@]}"; do
        local expanded_path="${p/#\~/$HOME}"
        # Skip if path doesn't exist
        [[ ! -e "$expanded_path" ]] && continue

        # Safety check: Skip if path ends with a common directory name (indicates empty app_name/bundle_id)
        # This prevents deletion of entire Library subdirectories when bundle_id is empty
        case "$expanded_path" in
            */Library/Application\ Support | */Library/Application\ Support/ | \
                */Library/Caches | */Library/Caches/ | \
                */Library/Logs | */Library/Logs/ | \
                */Library/Containers | */Library/Containers/ | \
                */Library/WebKit | */Library/WebKit/ | \
                */Library/HTTPStorages | */Library/HTTPStorages/ | \
                */Library/Application\ Scripts | */Library/Application\ Scripts/ | \
                */Library/Autosave\ Information | */Library/Autosave\ Information/ | \
                */Library/Group\ Containers | */Library/Group\ Containers/)
                continue
                ;;
        esac

        files_to_clean+=("$expanded_path")
    done

    # Handle Preferences and ByHost variants (only if bundle_id is valid)
    if [[ -n "$bundle_id" && "$bundle_id" != "unknown" && ${#bundle_id} -gt 3 ]]; then
        [[ -f ~/Library/Preferences/"$bundle_id".plist ]] && files_to_clean+=("$HOME/Library/Preferences/$bundle_id.plist")
        [[ -d ~/Library/Preferences/ByHost ]] && while IFS= read -r -d '' pref; do
            files_to_clean+=("$pref")
        done < <(command find -- ~/Library/Preferences/ByHost -maxdepth 1 \( -name "$bundle_id*.plist" \) -print0 2> /dev/null)

        # Group Containers (special handling)
        if [[ -d ~/Library/Group\ Containers ]]; then
            while IFS= read -r -d '' container; do
                files_to_clean+=("$container")
            done < <(command find -- ~/Library/Group\ Containers -maxdepth 1 \( -name "*$bundle_id*" \) -print0 2> /dev/null)
        fi
    fi

    # Launch Agents by name (special handling)
    if [[ ${#app_name} -gt 3 ]] && [[ -d ~/Library/LaunchAgents ]]; then
        while IFS= read -r -d '' plist; do
            files_to_clean+=("$plist")
        done < <(command find -- ~/Library/LaunchAgents -maxdepth 1 \( -name "*$app_name*.plist" \) -print0 2> /dev/null)
    fi

    # Handle specialized toolchains and development environments
    # 1. DevEco-Studio (Huawei)
    if [[ "$app_name" =~ DevEco|deveco ]] || [[ "$bundle_id" =~ huawei.*deveco ]]; then
        for d in ~/DevEcoStudioProjects ~/DevEco-Studio ~/Library/Application\ Support/Huawei ~/Library/Caches/Huawei ~/Library/Logs/Huawei ~/Library/Huawei ~/Huawei ~/HarmonyOS ~/.huawei ~/.ohos; do
            [[ -d "$d" ]] && files_to_clean+=("$d")
        done
    fi

    # 2. Android Studio (Google)
    if [[ "$app_name" =~ Android.*Studio|android.*studio ]] || [[ "$bundle_id" =~ google.*android.*studio|jetbrains.*android ]]; then
        for d in ~/AndroidStudioProjects ~/Library/Android ~/.android ~/.gradle; do
            [[ -d "$d" ]] && files_to_clean+=("$d")
        done
        [[ -d ~/Library/Application\ Support/Google ]] && while IFS= read -r -d '' d; do files_to_clean+=("$d"); done < <(command find -- ~/Library/Application\ Support/Google -maxdepth 1 -name "AndroidStudio*" -print0 2> /dev/null)
    fi

    # 3. Xcode (Apple)
    if [[ "$app_name" =~ Xcode|xcode ]] || [[ "$bundle_id" =~ apple.*xcode ]]; then
        [[ -d ~/Library/Developer ]] && files_to_clean+=("$HOME/Library/Developer")
        [[ -d ~/.Xcode ]] && files_to_clean+=("$HOME/.Xcode")
    fi

    # 4. JetBrains (IDE settings)
    if [[ "$bundle_id" =~ jetbrains ]] || [[ "$app_name" =~ IntelliJ|PyCharm|WebStorm|GoLand|RubyMine|PhpStorm|CLion|DataGrip|Rider ]]; then
        for base in ~/Library/Application\ Support/JetBrains ~/Library/Caches/JetBrains ~/Library/Logs/JetBrains; do
            [[ -d "$base" ]] && while IFS= read -r -d '' d; do files_to_clean+=("$d"); done < <(command find -- "$base" -maxdepth 1 -name "${app_name}*" -print0 2> /dev/null)
        done
    fi

    # 5. Unity / Unreal / Godot
    [[ "$app_name" =~ Unity|unity ]] && [[ -d ~/Library/Unity ]] && files_to_clean+=("$HOME/Library/Unity")
    [[ "$app_name" =~ Unreal|unreal ]] && [[ -d ~/Library/Application\ Support/Epic ]] && files_to_clean+=("$HOME/Library/Application Support/Epic")
    [[ "$app_name" =~ Godot|godot ]] && [[ -d ~/Library/Application\ Support/Godot ]] && files_to_clean+=("$HOME/Library/Application Support/Godot")

    # 6. Tools
    [[ "$bundle_id" =~ microsoft.*vscode ]] && [[ -d ~/.vscode ]] && files_to_clean+=("$HOME/.vscode")
    [[ "$app_name" =~ Docker ]] && [[ -d ~/.docker ]] && files_to_clean+=("$HOME/.docker")

    # Output results
    if [[ ${#files_to_clean[@]} -gt 0 ]]; then
        printf '%s\n' "${files_to_clean[@]}"
    fi
    return 0
}

# Locate system-level application files
find_app_system_files() {
    local bundle_id="$1"
    local app_name="$2"
    local -a system_files=()

    # Sanitized App Name (remove spaces)
    local nospace_name="${app_name// /}"

    # Standard system path patterns
    local -a system_patterns=(
        "/Library/Application Support/$app_name"
        "/Library/Application Support/$bundle_id"
        "/Library/LaunchAgents/$bundle_id.plist"
        "/Library/LaunchDaemons/$bundle_id.plist"
        "/Library/Preferences/$bundle_id.plist"
        "/Library/Receipts/$bundle_id.bom"
        "/Library/Receipts/$bundle_id.plist"
        "/Library/Frameworks/$app_name.framework"
        "/Library/Internet Plug-Ins/$app_name.plugin"
        "/Library/Input Methods/$app_name.app"
        "/Library/Input Methods/$bundle_id.app"
        "/Library/Audio/Plug-Ins/Components/$app_name.component"
        "/Library/Audio/Plug-Ins/VST/$app_name.vst"
        "/Library/Audio/Plug-Ins/VST3/$app_name.vst3"
        "/Library/Audio/Plug-Ins/Digidesign/$app_name.dpm"
        "/Library/QuickLook/$app_name.qlgenerator"
        "/Library/PreferencePanes/$app_name.prefPane"
        "/Library/Screen Savers/$app_name.saver"
        "/Library/Caches/$bundle_id"
        "/Library/Caches/$app_name"
    )

    if [[ ${#app_name} -gt 3 && "$app_name" =~ [[:space:]] ]]; then
        system_patterns+=(
            "/Library/Application Support/$nospace_name"
            "/Library/Caches/$nospace_name"
            "/Library/Logs/$nospace_name"
        )
    fi

    # Process patterns
    for p in "${system_patterns[@]}"; do
        [[ ! -e "$p" ]] && continue

        # Safety check: Skip if path ends with a common directory name (indicates empty app_name/bundle_id)
        case "$p" in
            /Library/Application\ Support | /Library/Application\ Support/ | \
                /Library/Caches | /Library/Caches/ | \
                /Library/Logs | /Library/Logs/)
                continue
                ;;
        esac

        system_files+=("$p")
    done

    # System LaunchAgents/LaunchDaemons by name
    if [[ ${#app_name} -gt 3 ]]; then
        for base in /Library/LaunchAgents /Library/LaunchDaemons; do
            [[ -d "$base" ]] && while IFS= read -r -d '' plist; do
                system_files+=("$plist")
            done < <(command find -- "$base" -maxdepth 1 \( -name "*$app_name*.plist" \) -print0 2> /dev/null)
        done
    fi

    # Privileged Helper Tools and Receipts (special handling)
    # Only search with bundle_id if it's valid (not empty and not "unknown")
    if [[ -n "$bundle_id" && "$bundle_id" != "unknown" && ${#bundle_id} -gt 3 ]]; then
        [[ -d /Library/PrivilegedHelperTools ]] && while IFS= read -r -d '' helper; do
            system_files+=("$helper")
        done < <(command find -- /Library/PrivilegedHelperTools -maxdepth 1 \( -name "$bundle_id*" \) -print0 2> /dev/null)

        [[ -d /private/var/db/receipts ]] && while IFS= read -r -d '' receipt; do
            system_files+=("$receipt")
        done < <(command find -- /private/var/db/receipts -maxdepth 1 \( -name "*$bundle_id*" \) -print0 2> /dev/null)
    fi

    if [[ ${#system_files[@]} -gt 0 ]]; then
        printf '%s\n' "${system_files[@]}"
    fi

    # Find files from receipts (Deep Scan)
    find_app_receipt_files "$bundle_id"
}

# Locate files using installation receipts (BOM)
find_app_receipt_files() {
    local bundle_id="$1"

    # Skip if no bundle ID
    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 0

    local -a receipt_files=()
    local -a bom_files=()

    # Find receipts matching the bundle ID
    # Usually in /var/db/receipts/
    if [[ -d /private/var/db/receipts ]]; then
        while IFS= read -r -d '' bom; do
            bom_files+=("$bom")
        done < <(find /private/var/db/receipts -maxdepth 1 -name "${bundle_id}*.bom" -print0 2> /dev/null)
    fi

    # Process bom files if any found
    if [[ ${#bom_files[@]} -gt 0 ]]; then
        for bom_file in "${bom_files[@]}"; do
            [[ ! -f "$bom_file" ]] && continue

            # Parse bom file
            # lsbom -f: file paths only
            # -s: suppress output (convert to text)
            local bom_content
            bom_content=$(lsbom -f -s "$bom_file" 2> /dev/null)

            while IFS= read -r file_path; do
                # Standardize path (remove leading dot)
                local clean_path="${file_path#.}"

                # Ensure absolute path
                if [[ "$clean_path" != /* ]]; then
                    clean_path="/$clean_path"
                fi

                # ------------------------------------------------------------------------
                # Safety check: restrict removal to trusted paths
                # ------------------------------------------------------------------------
                local is_safe=false

                # Whitelisted prefixes
                case "$clean_path" in
                    /Applications/*) is_safe=true ;;
                    /Users/*) is_safe=true ;;
                    /usr/local/*) is_safe=true ;;
                    /opt/*) is_safe=true ;;
                    /Library/*)
                        # Filter sub-paths in /Library to avoid system damage
                        # Allow safely: Application Support, Caches, Logs, Preferences
                        case "$clean_path" in
                            /Library/Application\ Support/*) is_safe=true ;;
                            /Library/Caches/*) is_safe=true ;;
                            /Library/Logs/*) is_safe=true ;;
                            /Library/Preferences/*) is_safe=true ;;
                            /Library/PrivilegedHelperTools/*) is_safe=true ;;
                            /Library/LaunchAgents/*) is_safe=true ;;
                            /Library/LaunchDaemons/*) is_safe=true ;;
                            /Library/Internet\ Plug-Ins/*) is_safe=true ;;
                            /Library/Audio/Plug-Ins/*) is_safe=true ;;
                            /Library/Extensions/*) is_safe=false ;; # Default unsafe
                            *) is_safe=false ;;
                        esac
                        ;;
                esac

                # Hard blocks
                case "$clean_path" in
                    /System/* | /usr/bin/* | /usr/lib/* | /bin/* | /sbin/*) is_safe=false ;;
                esac

                if [[ "$is_safe" == "true" && -e "$clean_path" ]]; then
                    # If lsbom lists /Applications, skip to avoid system damage.
                    # Extra check: path must be deep enough?
                    # If path is just "/Applications", skip.
                    if [[ "$clean_path" == "/Applications" || "$clean_path" == "/Library" || "$clean_path" == "/usr/local" ]]; then
                        continue
                    fi

                    receipt_files+=("$clean_path")
                fi

            done <<< "$bom_content"
        done
    fi
    if [[ ${#receipt_files[@]} -gt 0 ]]; then
        printf '%s\n' "${receipt_files[@]}"
    fi
}

# Terminate a running application
force_kill_app() {
    # Gracefully terminates or force-kills an application
    local app_name="$1"
    local app_path="${2:-""}"

    # Get the executable name from bundle if app_path is provided
    local exec_name=""
    if [[ -n "$app_path" && -e "$app_path/Contents/Info.plist" ]]; then
        exec_name=$(defaults read "$app_path/Contents/Info.plist" CFBundleExecutable 2> /dev/null || echo "")
    fi

    # Use executable name for precise matching, fallback to app name
    local match_pattern="${exec_name:-$app_name}"

    # Check if process is running using exact match only
    if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
        return 0
    fi

    # Try graceful termination first
    pkill -x "$match_pattern" 2> /dev/null || true
    sleep 2

    # Check again after graceful kill
    if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
        return 0
    fi

    # Force kill if still running
    pkill -9 -x "$match_pattern" 2> /dev/null || true
    sleep 2

    # If still running and sudo is available, try with sudo
    if pgrep -x "$match_pattern" > /dev/null 2>&1; then
        if sudo -n true 2> /dev/null; then
            sudo pkill -9 -x "$match_pattern" 2> /dev/null || true
            sleep 2
        fi
    fi

    # Final check with longer timeout for stubborn processes
    local retries=3
    while [[ $retries -gt 0 ]]; do
        if ! pgrep -x "$match_pattern" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        ((retries--))
    done

    # Still running after all attempts
    pgrep -x "$match_pattern" > /dev/null 2>&1 && return 1 || return 0
}

# Note: calculate_total_size() is defined in lib/core/file_ops.sh
