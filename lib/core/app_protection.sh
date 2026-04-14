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

# Declare WHITELIST_PATTERNS if not already set (used by is_path_whitelisted)
if ! declare -p WHITELIST_PATTERNS &> /dev/null; then
    declare -a WHITELIST_PATTERNS=()
fi

# Application Management

# ============================================================================
# Performance Note:
# - SYSTEM_CRITICAL_BUNDLES_FAST: Fast wildcard patterns for cleanup operations
# - SYSTEM_CRITICAL_BUNDLES: Detailed list for uninstall protection (lazy-loaded)
# ============================================================================

# Fast patterns for cleanup operations (used by should_protect_data)
# These wildcards provide adequate protection with minimal performance impact
readonly SYSTEM_CRITICAL_BUNDLES_FAST=(
    "com.apple.*"
    "loginwindow"
    "dock"
    "systempreferences"
    "finder"
    "safari"
    "backgroundtaskmanagement*"
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
    "org.pqrs.Karabiner*"
    # CUPS printing subsystem ships with macOS; there is no parent .app to
    # anchor it, so org.cups.* prefs always look "orphaned" to bundle-ID
    # matching. Deleting them wipes the default printer and recent-printer
    # list, which users see as lost saved printers. See #731.
    "org.cups.*"
)

# Detailed list for uninstall protection
# Critical system components protected from uninstallation
# Note: We explicitly list system components instead of using "com.apple.*" wildcard
# to allow uninstallation of user-installed Apple apps (Xcode, Final Cut Pro, etc.)
readonly SYSTEM_CRITICAL_BUNDLES=(
    # Core system applications (in /System/Applications/)
    "com.apple.finder"
    "com.apple.dock"
    "com.apple.Safari"
    "com.apple.mail"
    "com.apple.systempreferences"
    "com.apple.SystemSettings"
    "com.apple.Settings*"
    "com.apple.controlcenter*"
    "com.apple.Spotlight"
    "com.apple.notificationcenterui"
    "com.apple.loginwindow"
    "com.apple.Preview"
    "com.apple.TextEdit"
    "com.apple.Notes"
    "com.apple.reminders"
    "com.apple.iCal"
    "com.apple.AddressBook"
    "com.apple.Photos"
    "com.apple.AppStore"
    "com.apple.calculator"
    "com.apple.Dictionary"
    "com.apple.ScreenSharing"
    "com.apple.ActivityMonitor"
    "com.apple.Console"
    "com.apple.DiskUtility"
    "com.apple.KeychainAccess"
    "com.apple.DigitalColorMeter"
    "com.apple.grapher"
    "com.apple.Terminal"
    "com.apple.ScriptEditor2"
    "com.apple.VoiceOverUtility"
    "com.apple.BluetoothFileExchange"
    "com.apple.print.PrinterProxy"
    "com.apple.systempreferences*"
    "com.apple.SystemProfiler"
    "com.apple.FontBook"
    "com.apple.ColorSyncUtility"
    "com.apple.audio.AudioMIDISetup"
    "com.apple.DirectoryUtility"
    "com.apple.NetworkUtility"
    "com.apple.exposelauncher"
    "com.apple.MigrateAssistant"
    "com.apple.RAIDUtility"
    "com.apple.BootCampAssistant"

    # System services and daemons
    "com.apple.SecurityAgent"
    "com.apple.CoreServices*"
    "com.apple.SystemUIServer"
    "com.apple.backgroundtaskmanagement*"
    "com.apple.loginitems*"
    "com.apple.sharedfilelist*"
    "com.apple.sfl*"
    "com.apple.coreservices*"
    "com.apple.metadata*"
    "com.apple.MobileSoftwareUpdate*"
    "com.apple.SoftwareUpdate*"
    "com.apple.installer*"
    "com.apple.frameworks*"
    "com.apple.security*"
    "com.apple.keychain*"
    "com.apple.trustd*"
    "com.apple.securityd*"
    "com.apple.cloudd*"
    "com.apple.iCloud*"
    "com.apple.WiFi*"
    "com.apple.airport*"
    "com.apple.Bluetooth*"

    # Input methods (system built-in)
    "com.apple.inputmethod.*"
    "com.apple.inputsource*"
    "com.apple.TextInput*"
    "com.apple.CharacterPicker*"
    "com.apple.PressAndHold*"

    # Legacy pattern-based entries (non com.apple.*)
    "loginwindow"
    "dock"
    "systempreferences"
    "finder"
    "safari"
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
    "org.pqrs.Karabiner*"
)

# Apple apps that CAN be uninstalled (from App Store or developer.apple.com)
readonly APPLE_UNINSTALLABLE_APPS=(
    "com.apple.dt.*"      # Xcode, Instruments, FileMerge
    "com.apple.FinalCut*" # Final Cut Pro
    "com.apple.Motion"
    "com.apple.Compressor"
    "com.apple.logic*"      # Logic Pro
    "com.apple.garageband*" # GarageBand
    "com.apple.iMovie"
    "com.apple.iWork.*" # Pages, Numbers, Keynote
    "com.apple.MainStage*"
    "com.apple.server.*"    # macOS Server
    "com.apple.Playgrounds" # Swift Playgrounds
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

    # System Utilities & Cleanup
    "com.nektony.*"
    "com.macpaw.*"
    "com.freemacsoft.AppCleaner"
    "com.omnigroup.omnidisksweeper"
    "com.daisydiskapp.*"
    "com.tunabellysoftware.*"
    "com.grandperspectiv.*"
    "com.binaryfruit.*"

    # Password Managers
    "com.1password.*"
    "com.agilebits.*"
    "com.lastpass.*"
    "com.dashlane.*"
    "com.bitwarden.*"
    "com.keepassx.*"
    "org.keepassx.*"
    "org.keepassxc.*"
    "com.authy.*"
    "com.yubico.*"

    # IDEs & Editors
    "com.jetbrains.*"
    "JetBrains*"
    "com.microsoft.VSCode"
    "com.visualstudio.code.*"
    "com.sublimetext.*"
    "com.sublimehq.*"
    "com.microsoft.VSCodeInsiders"
    "com.apple.dt.Xcode"
    "com.coteditor.CotEditor"
    "com.macromates.TextMate"
    "com.panic.Nova"
    "abnerworks.Typora"
    "com.uranusjr.macdown"

    # AI & LLM Tools
    "com.todesktop.*"
    "Cursor"
    "com.anthropic.claude*"
    "Claude"
    "com.openai.chat*"
    "ChatGPT"
    "com.ollama.ollama"
    "Ollama"
    "com.lmstudio.lmstudio"
    "LM Studio"
    "co.supertool.chatbox"
    "page.jan.jan"
    "com.huggingface.huggingchat"
    "Gemini"
    "com.perplexity.Perplexity"
    "com.drawthings.DrawThings"
    "com.divamgupta.diffusionbee"
    "com.exafunction.windsurf"
    "com.quora.poe.electron"
    "chat.openai.com.*"

    # Database Clients
    "com.sequelpro.*"
    "com.sequel-ace.*"
    "com.tinyapp.*"
    "com.dbeaver.*"
    "com.navicat.*"
    "com.mongodb.compass"
    "com.redis.RedisInsight"
    "com.pgadmin.pgadmin4"
    "com.eggerapps.Sequel-Pro"
    "com.valentina-db.Valentina-Studio"
    "com.dbvis.DbVisualizer"

    # API & Network Tools
    "com.postmanlabs.mac"
    "com.konghq.insomnia"
    "com.CharlesProxy.*"
    "com.proxyman.*"
    "com.getpaw.*"
    "com.luckymarmot.Paw"
    "com.charlesproxy.charles"
    "com.telerik.Fiddler"
    "com.usebruno.app"

    # Network Proxy & VPN Tools (Clash variants - use specific patterns to avoid false positives)
    "com.clash.*"
    "ClashX*"
    "clash-*"
    "Clash-*"
    "*-clash"
    "*-Clash"
    "clash.*"
    "Clash.*"
    "clash_*"
    "*clash-verge*"
    "*Clash-Verge*"
    "clashverge*"
    "ClashVerge*"
    "com.nssurge.surge-mac"
    "*surge*"
    "*Surge*"
    "mihomo*"
    "*openvpn*"
    "*OpenVPN*"
    "net.openvpn.*"

    # Proxy Clients
    "*ShadowsocksX-NG*"
    "com.qiuyuzhou.*"
    "*v2ray*"
    "*V2Ray*"
    "*v2box*"
    "*V2Box*"
    "*nekoray*"
    "*sing-box*"
    "*OneBox*"
    "*hiddify*"
    "*Hiddify*"
    "*loon*"
    "*Loon*"
    "*quantumult*"

    # Mesh & Corporate VPNs
    "*tailscale*"
    "io.tailscale.*"
    "*zerotier*"
    "com.zerotier.*"
    "*1dot1dot1dot1*" # Cloudflare WARP
    "*cloudflare*warp*"

    # Commercial VPNs
    "*nordvpn*"
    "*expressvpn*"
    "*protonvpn*"
    "*surfshark*"
    "*windscribe*"
    "*mullvad*"
    "*privateinternetaccess*"

    # Screensaver & Wallpaper
    "*Aerial.saver*"
    "com.JohnCoates.Aerial*"
    "*Fliqlo*"
    "*fliqlo*"

    # Git & Version Control
    "com.github.GitHubDesktop"
    "com.sublimemerge"
    "com.torusknot.SourceTreeNotMAS"
    "com.git-tower.Tower*"
    "com.gitfox.GitFox"
    "com.github.Gitify"
    "com.fork.Fork"
    "com.axosoft.gitkraken"

    # Terminal & Shell
    "com.googlecode.iterm2"
    "net.kovidgoyal.kitty"
    "io.alacritty"
    "com.github.wez.wezterm"
    "com.hyper.Hyper"
    "com.mizage.divvy"
    "com.fig.Fig"
    "dev.warp.Warp-Stable"
    "com.termius-dmg"

    # Docker & Virtualization
    "com.docker.docker"
    "com.getutm.UTM"
    "com.vmware.fusion"
    "com.parallels.desktop.*"
    "org.virtualbox.app.VirtualBox"
    "com.vagrant.*"
    "com.orbstack.OrbStack"

    # System Monitoring
    "com.bjango.istatmenus*"
    "eu.exelban.Stats"
    "com.monitorcontrol.*"
    "com.bresink.system-toolkit.*"
    "com.mediaatelier.MenuMeters"
    "com.activity-indicator.app"
    "net.cindori.sensei"

    # Window Management
    "com.macitbetter.*" # BetterTouchTool, BetterSnapTool
    "com.hegenberg.*"
    "com.manytricks.*" # Moom, Witch, etc.
    "com.divisiblebyzero.*"
    "com.koingdev.*"
    "com.if.Amphetamine"
    "com.lwouis.alt-tab-macos"
    "net.matthewpalmer.Vanilla"
    "com.lightheadsw.Caffeine"
    "com.contextual.Contexts"
    "com.amethyst.Amethyst"
    "com.knollsoft.Rectangle"
    "com.knollsoft.Hookshot"
    "com.surteesstudios.Bartender"
    "com.gaosun.eul"
    "com.pointum.hazeover"

    # Launcher & Automation
    "com.runningwithcrayons.Alfred"
    "com.raycast.macos"
    "com.blacktree.Quicksilver"
    "com.stairways.keyboardmaestro.*"
    "com.manytricks.Butler"
    "com.happenapps.Quitter"
    "com.pilotmoon.scroll-reverser"
    "org.pqrs.Karabiner-Elements"
    "com.apple.Automator"

    # Note-Taking
    "com.bear-writer.*"
    "com.typora.*"
    "com.ulyssesapp.*"
    "com.literatureandlatte.*"
    "com.dayoneapp.*"
    "notion.id"
    "md.obsidian"
    "com.logseq.logseq"
    "com.evernote.Evernote"
    "com.onenote.mac"
    "com.omnigroup.OmniOutliner*"
    "net.shinyfrog.bear"
    "com.goodnotes.GoodNotes"
    "com.marginnote.MarginNote*"
    "com.roamresearch.*"
    "com.reflect.ReflectApp"
    "com.inkdrop.*"

    # Design & Creative
    "com.adobe.*"
    "com.bohemiancoding.*"
    "com.figma.*"
    "com.framerx.*"
    "com.zeplin.*"
    "com.invisionapp.*"
    "com.principle.*"
    "com.pixelmatorteam.*"
    "com.affinitydesigner.*"
    "com.affinityphoto.*"
    "com.affinitypublisher.*"
    "com.linearity.curve"
    "com.canva.CanvaDesktop"
    "com.maxon.cinema4d"
    "com.autodesk.*"
    "com.sketchup.*"

    # Communication
    "com.tencent.xinWeChat"
    "com.tencent.qq"
    "com.alibaba.DingTalkMac"
    "com.alibaba.AliLang.osx"
    "com.alibaba.alilang3.osx.ShipIt"
    "com.alibaba.AlilangMgr.QueryNetworkInfo"
    "us.zoom.xos"
    "com.microsoft.teams*"
    "com.slack.Slack"
    "com.hnc.Discord"
    "app.legcord.Legcord"
    "org.telegram.desktop"
    "ru.keepcoder.Telegram"
    "net.whatsapp.WhatsApp"
    "com.skype.skype"
    "com.cisco.webexmeetings"
    "com.ringcentral.RingCentral"
    "com.readdle.smartemail-Mac"
    "com.airmail.*"
    "com.postbox-inc.postbox"
    "com.tinyspeck.slackmacgap"

    # Task Management
    "com.omnigroup.OmniFocus*"
    "com.culturedcode.*"
    "com.todoist.*"
    "com.any.do.*"
    "com.ticktick.*"
    "com.microsoft.to-do"
    "com.trello.trello"
    "com.asana.nativeapp"
    "com.clickup.*"
    "com.monday.desktop"
    "com.airtable.airtable"
    "com.notion.id"
    "com.linear.linear"

    # File Transfer & Sync
    "com.panic.transmit*"
    "com.binarynights.ForkLift*"
    "com.noodlesoft.Hazel"
    "com.cyberduck.Cyberduck"
    "io.filezilla.FileZilla"
    "com.apple.Xcode.CloudDocuments"
    "com.synology.*"

    # Cloud Storage & Backup
    "com.dropbox.*"
    "com.getdropbox.*"
    "*dropbox*"
    "ws.agile.*"
    "com.backblaze.*"
    "*backblaze*"
    "com.box.desktop*"
    "*box.desktop*"
    "com.microsoft.OneDrive*"
    "com.microsoft.SyncReporter"
    "*OneDrive*"
    "com.google.GoogleDrive"
    "com.google.keystone*"
    "*GoogleDrive*"
    "com.amazon.drive"
    "com.apple.bird"
    "com.apple.CloudDocs*"
    "com.displaylink.*"
    "com.fujitsu.pfu.ScanSnap*"
    "com.citrix.*"
    "org.xquartz.*"
    "us.zoom.updater*"
    "com.DigiDNA.iMazing*"
    "com.shirtpocket.*"
    "homebrew.mxcl.*"

    # Screenshot & Recording
    "com.cleanshot.*"
    "com.xnipapp.xnip"
    "com.reincubate.camo"
    "com.tunabellysoftware.ScreenFloat"
    "net.telestream.screenflow*"
    "com.techsmith.snagit*"
    "com.techsmith.camtasia*"
    "com.obsidianapp.screenrecorder"
    "com.kap.Kap"
    "com.getkap.*"
    "com.linebreak.CloudApp"
    "com.droplr.droplr-mac"

    # Media & Entertainment
    "com.spotify.client"
    "com.apple.Music"
    "com.apple.podcasts"
    "com.apple.BKAgentService"
    "com.apple.iBooksX"
    "com.apple.iBooks"
    "com.blackmagic-design.*"
    "com.colliderli.iina"
    "org.videolan.vlc"
    "io.mpv"
    "tv.plex.player.desktop"
    "com.netease.163music"

    # Web Browsers
    "Firefox"
    "org.mozilla.*"

    # License & App Stores
    "com.paddle.Paddle*"
    "com.setapp.DesktopClient"
    "com.devmate.*"
    "org.sparkle-project.Sparkle"
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

# Helper to build regex from array (Bash 3.2 compatible - no namerefs)
# $1: Variable name to store result
# $2...: Array elements (passed as expanded list)
build_regex_var() {
    local var_name="$1"
    shift
    local regex=""
    for pattern in "$@"; do
        # Escape dots . -> \.
        local p="${pattern//./\\.}"
        # Convert * to .*
        p="${p//\*/.*}"
        # Start and end anchors
        p="^${p}$"

        if [[ -z "$regex" ]]; then
            regex="$p"
        else
            regex="$regex|$p"
        fi
    done
    eval "$var_name=\"\$regex\""
}

# Lazy-loaded regex (only built when needed)
APPLE_UNINSTALLABLE_REGEX=""
SYSTEM_CRITICAL_REGEX=""
SYSTEM_CRITICAL_FAST_REGEX=""
DATA_PROTECTED_REGEX=""

_ensure_uninstall_regex() {
    if [[ -z "$SYSTEM_CRITICAL_REGEX" ]]; then
        build_regex_var APPLE_UNINSTALLABLE_REGEX "${APPLE_UNINSTALLABLE_APPS[@]}"
        build_regex_var SYSTEM_CRITICAL_REGEX "${SYSTEM_CRITICAL_BUNDLES[@]}"
    fi
}

_ensure_data_protection_regex() {
    if [[ -z "$SYSTEM_CRITICAL_FAST_REGEX" ]]; then
        build_regex_var SYSTEM_CRITICAL_FAST_REGEX "${SYSTEM_CRITICAL_BUNDLES_FAST[@]}"
        build_regex_var DATA_PROTECTED_REGEX "${DATA_PROTECTED_BUNDLES[@]}"
    fi
}

# Check if application is a protected system component
should_protect_from_uninstall() {
    local bundle_id="$1"

    _ensure_uninstall_regex

    if [[ "$bundle_id" =~ $APPLE_UNINSTALLABLE_REGEX ]]; then
        return 1
    fi

    if [[ "$bundle_id" =~ $SYSTEM_CRITICAL_REGEX ]]; then
        return 0
    fi

    return 1
}

# Check if application data should be protected during cleanup
should_protect_data() {
    local bundle_id="$1"

    case "$bundle_id" in
        com.apple.* | loginwindow | dock | systempreferences | finder | safari)
            return 0
            ;;
        # CUPS is an OS-provided subsystem with no user-facing app; without this
        # guard `~/Library/Preferences/org.cups.PrintingPrefs.plist` (which holds
        # the default printer and recent printers) looks orphaned. See #731.
        org.cups.*)
            return 0
            ;;
        backgroundtaskmanagement* | keychain* | security* | bluetooth* | wifi* | network* | tcc)
            return 0
            ;;
        notification* | accessibility* | universalaccess* | HIToolbox*)
            return 0
            ;;
        *inputmethod* | *InputMethod* | *IME | textinput* | TextInput*)
            return 0
            ;;
        keyboard* | Keyboard* | inputsource* | InputSource* | keylayout* | KeyLayout*)
            return 0
            ;;
        GlobalPreferences | .GlobalPreferences | org.pqrs.Karabiner*)
            return 0
            ;;
        com.1password.* | com.agilebits.* | com.lastpass.* | com.dashlane.* | com.bitwarden.*)
            return 0
            ;;
        com.jetbrains.* | JetBrains* | com.microsoft.* | com.visualstudio.*)
            return 0
            ;;
        com.sublimetext.* | com.sublimehq.* | Cursor | Claude | ChatGPT | Ollama)
            return 0
            ;;
        # Specific match to avoid ShellCheck redundancy warning with com.clash.*
        com.clash.app)
            return 0
            ;;
        com.nssurge.* | com.v2ray.* | com.clash.* | ClashX* | Surge* | Shadowrocket* | Quantumult*)
            return 0
            ;;
        clash-* | Clash-* | *-clash | *-Clash | clash.* | Clash.* | clash_* | *clash-verge* | *Clash-Verge* | clashverge* | ClashVerge*)
            return 0
            ;;
        com.docker.* | com.getpostman.* | com.insomnia.*)
            return 0
            ;;
        com.tencent.* | com.sogou.* | com.baidu.* | com.googlecode.* | im.rime.*)
            # These might have wildcards, check detailed list
            for pattern in "${DATA_PROTECTED_BUNDLES[@]}"; do
                if bundle_matches_pattern "$bundle_id" "$pattern"; then
                    return 0
                fi
            done
            return 1
            ;;
    esac

    # Fallback: check against the full DATA_PROTECTED_BUNDLES list
    for pattern in "${DATA_PROTECTED_BUNDLES[@]}"; do
        if bundle_matches_pattern "$bundle_id" "$pattern"; then
            return 0
        fi
    done

    return 1
}

# Check if a path is protected from deletion
# Centralized logic to protect system settings, control center, and critical apps
#
# In uninstall mode (MOLE_UNINSTALL_MODE=1), only system-critical components are protected.
# Data-protected apps (VPNs, dev tools, etc.) can be uninstalled when user explicitly chooses to.
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
        # In uninstall mode, only system components are protected; skip data protection
        if [[ "${MOLE_UNINSTALL_MODE:-0}" != "1" ]] && should_protect_data "$bundle_id"; then
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
        # Protect Mole's own runtime logs so cleanup cannot delete its active log targets.
        */Library/Logs/mole | */Library/Logs/mole/ | */Library/Logs/mole/*)
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
        # CoreAudio and audio subsystem caches (issue #553)
        # Cleaning these can cause audio output loss on Intel Macs
        *com.apple.coreaudio* | *com.apple.audio.* | *coreaudiod*)
            return 0
            ;;
    esac

    # 6. Match full path against protected patterns
    # This catches things like /Users/tw93/Library/Caches/Claude when pattern is *Claude*
    # In uninstall mode, only check system-critical bundles (user explicitly chose to uninstall)
    if [[ "${MOLE_UNINSTALL_MODE:-0}" == "1" ]]; then
        # Uninstall mode: first check if it's an uninstallable Apple app
        for pattern in "${APPLE_UNINSTALLABLE_APPS[@]}"; do
            if bundle_matches_pattern "$path" "$pattern"; then
                return 1 # Can be uninstalled
            fi
        done
        # Then check system-critical components
        for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}"; do
            if bundle_matches_pattern "$path" "$pattern"; then
                return 0
            fi
        done
    else
        # Normal mode (cleanup): protect both system-critical and data-protected bundles
        for pattern in "${SYSTEM_CRITICAL_BUNDLES[@]}" "${DATA_PROTECTED_BUNDLES[@]}"; do
            if bundle_matches_pattern "$path" "$pattern"; then
                return 0
            fi
        done
    fi

    # 7. Check if the filename itself matches any protected patterns
    # Skip in uninstall mode - user explicitly chose to remove this app
    if [[ "${MOLE_UNINSTALL_MODE:-0}" != "1" ]]; then
        local filename
        filename=$(basename "$path")
        if should_protect_data "$filename"; then
            return 0
        fi
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

    # Early validation: require at least one valid identifier
    # Skip scanning if both bundle_id and app_name are invalid
    if [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] &&
        [[ -z "$app_name" || ${#app_name} -lt 2 ]]; then
        return 0 # Silent return to avoid invalid scanning
    fi

    local -a files_to_clean=()

    # Normalize app name for matching - generate all common naming variants
    # Apps use inconsistent naming: "Maestro Studio" vs "maestro-studio" vs "MaestroStudio"
    # Note: Using tr for lowercase conversion (Bash 3.2 compatible, no ${var,,} support)
    local nospace_name="${app_name// /}"                                               # "Maestro Studio" -> "MaestroStudio"
    local underscore_name="${app_name// /_}"                                           # "Maestro Studio" -> "Maestro_Studio"
    local hyphen_name="${app_name// /-}"                                               # "Maestro Studio" -> "Maestro-Studio"
    local lowercase_name=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')              # "Zed Nightly" -> "zed nightly"
    local lowercase_nospace=$(echo "$nospace_name" | tr '[:upper:]' '[:lower:]')       # "MaestroStudio" -> "maestrostudio"
    local lowercase_hyphen=$(echo "$hyphen_name" | tr '[:upper:]' '[:lower:]')         # "Maestro-Studio" -> "maestro-studio"
    local lowercase_underscore=$(echo "$underscore_name" | tr '[:upper:]' '[:lower:]') # "Maestro_Studio" -> "maestro_studio"

    # Extract base name by removing common version/channel suffixes
    # "Zed Nightly" -> "Zed", "Firefox Developer Edition" -> "Firefox"
    local base_name="$app_name"
    local version_suffixes="Nightly|Beta|Alpha|Dev|Canary|Preview|Insider|Edge|Stable|Release|RC|LTS"
    version_suffixes+="|Developer Edition|Technology Preview"
    if [[ "$app_name" =~ ^(.+)[[:space:]]+(${version_suffixes})$ ]]; then
        base_name="${BASH_REMATCH[1]}"
    fi
    local base_lowercase=$(echo "$base_name" | tr '[:upper:]' '[:lower:]') # "Zed" -> "zed"

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
        "$HOME/Library/HTTPStorages/$bundle_id.binarycookies"
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
        "$HOME/Library/SyncedPreferences/$bundle_id.plist"
        "$HOME/Library/Address Book Plug-Ins/$app_name.bundle"
        "$HOME/Library/Accessibility/$app_name.bundle"
        "$HOME/Library/Mail/Bundles/$app_name.mailbundle"
    )

    # Add all naming variants to cover inconsistent app directory naming
    # Issue #377: Apps create directories with various naming conventions
    if [[ ${#app_name} -gt 3 && "$app_name" =~ [[:space:]] ]]; then
        user_patterns+=(
            # Compound naming (MaestroStudio, Maestro_Studio, Maestro-Studio)
            "$HOME/Library/Application Support/$nospace_name"
            "$HOME/Library/Caches/$nospace_name"
            "$HOME/Library/Logs/$nospace_name"
            "$HOME/Library/Application Support/$underscore_name"
            "$HOME/Library/Application Support/$hyphen_name"
            # Lowercase variants (maestrostudio, maestro-studio, maestro_studio)
            "$HOME/.config/$lowercase_nospace"
            "$HOME/.config/$lowercase_hyphen"
            "$HOME/.config/$lowercase_underscore"
            "$HOME/.local/share/$lowercase_nospace"
            "$HOME/.local/share/$lowercase_hyphen"
            "$HOME/.local/share/$lowercase_underscore"
        )
    fi

    # Add base name variants for versioned apps (e.g., "Zed Nightly" -> check for "zed")
    if [[ "$base_name" != "$app_name" && ${#base_name} -gt 2 ]]; then
        user_patterns+=(
            "$HOME/Library/Application Support/$base_name"
            "$HOME/Library/Caches/$base_name"
            "$HOME/Library/Logs/$base_name"
            "$HOME/.config/$base_lowercase"
            "$HOME/.local/share/$base_lowercase"
            "$HOME/.$base_lowercase"
        )
    fi

    # Issue #422: Zed channel builds can leave data under another channel bundle id.
    # Example: uninstalling dev.zed.Zed-Nightly should also detect dev.zed.Zed-Preview leftovers.
    if [[ "$bundle_id" =~ ^dev\.zed\.Zed- ]] && [[ -d "$HOME/Library/HTTPStorages" ]]; then
        while IFS= read -r -d '' zed_http_storage; do
            files_to_clean+=("$zed_http_storage")
        done < <(command find "$HOME/Library/HTTPStorages" -maxdepth 1 -name "dev.zed.Zed-*" -print0 2> /dev/null)
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
        [[ -d ~/Library/Preferences/"$bundle_id" ]] && files_to_clean+=("$HOME/Library/Preferences/$bundle_id")
        [[ -d ~/Library/Preferences/ByHost ]] && while IFS= read -r -d '' pref; do
            files_to_clean+=("$pref")
        done < <(command find ~/Library/Preferences/ByHost -maxdepth 1 \( -name "$bundle_id*.plist" \) -print0 2> /dev/null)

        # NSURLSession download caches
        local nsurlsession_dl="$HOME/Library/Caches/com.apple.nsurlsessiond/Downloads/$bundle_id"
        [[ -d "$nsurlsession_dl" ]] && files_to_clean+=("$nsurlsession_dl")

        # Group Containers (special handling)
        if [[ -d ~/Library/Group\ Containers ]]; then
            while IFS= read -r -d '' container; do
                files_to_clean+=("$container")
            done < <(command find ~/Library/Group\ Containers -maxdepth 1 \( -name "*$bundle_id*" \) -print0 2> /dev/null)
        fi

        # App extensions often use bundle-id-derived directories rather than the
        # main bundle id exactly, for example share extensions or file providers.
        local -a derived_bundle_roots=(
            "$HOME/Library/Application Scripts"
            "$HOME/Library/Containers"
            "$HOME/Library/Application Support/FileProvider"
        )
        local derived_root=""
        local derived_path=""
        local existing_path=""
        local already_added=false
        for derived_root in "${derived_bundle_roots[@]}"; do
            [[ -d "$derived_root" ]] || continue
            while IFS= read -r -d '' derived_path; do
                already_added=false
                for existing_path in "${files_to_clean[@]}"; do
                    if [[ "$existing_path" == "$derived_path" ]]; then
                        already_added=true
                        break
                    fi
                done
                [[ "$already_added" == "true" ]] || files_to_clean+=("$derived_path")
            done < <(command find "$derived_root" -maxdepth 1 -type d -name "*$bundle_id*" -print0 2> /dev/null)
        done
    fi

    # Shared file lists (.sfl4 - recent documents etc.)
    if [[ -n "$bundle_id" && "$bundle_id" != "unknown" ]] && [[ -d "$HOME/Library/Application Support/com.apple.sharedfilelist" ]]; then
        while IFS= read -r -d '' sfl4_file; do
            files_to_clean+=("$sfl4_file")
        done < <(command find "$HOME/Library/Application Support/com.apple.sharedfilelist" -maxdepth 2 -name "${bundle_id}.sfl4" -print0 2> /dev/null)
    fi

    # Launch Agents by name (special handling)
    # Note: LaunchDaemons are system-level and handled in find_app_system_files()
    # Minimum 5-char threshold prevents false positives (e.g., "Time" matching system agents)
    # Short-name apps (e.g., Zoom, Arc) are still cleaned via bundle_id matching above
    # Security: Common words are excluded to prevent matching unrelated plist files
    if [[ ${#app_name} -ge 5 ]] && [[ -d ~/Library/LaunchAgents ]]; then
        # Skip common words that could match many unrelated LaunchAgents
        # These are either generic terms or names that overlap with system/common utilities
        local common_words="Music|Notes|Photos|Finder|Safari|Preview|Calendar|Contacts|Messages|Reminders|Clock|Weather|Stocks|Books|News|Podcasts|Voice|Files|Store|System|Helper|Agent|Daemon|Service|Update|Sync|Backup|Cloud|Manager|Monitor|Server|Client|Worker|Runner|Launcher|Driver|Plugin|Extension|Widget|Utility"
        if [[ "$app_name" =~ ^($common_words)$ ]]; then
            debug_log "Skipping LaunchAgent name search for common word: $app_name"
        else
            while IFS= read -r -d '' plist; do
                local plist_name=$(basename "$plist")
                # Skip Apple's LaunchAgents
                if [[ "$plist_name" =~ ^com\.apple\. ]]; then
                    continue
                fi
                files_to_clean+=("$plist")
            done < <(command find ~/Library/LaunchAgents -maxdepth 1 -name "*$app_name*.plist" -print0 2> /dev/null)
        fi
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
        for d in ~/AndroidStudioProjects ~/Library/Android ~/.android; do
            [[ -d "$d" ]] && files_to_clean+=("$d")
        done
        [[ -d ~/Library/Application\ Support/Google ]] && while IFS= read -r -d '' d; do files_to_clean+=("$d"); done < <(command find ~/Library/Application\ Support/Google -maxdepth 1 -name "AndroidStudio*" -print0 2> /dev/null)
    fi

    # 3. Xcode (Apple)
    if [[ "$app_name" =~ Xcode|xcode ]] || [[ "$bundle_id" =~ apple.*xcode ]]; then
        [[ -d ~/Library/Developer ]] && files_to_clean+=("$HOME/Library/Developer")
        [[ -d ~/.Xcode ]] && files_to_clean+=("$HOME/.Xcode")
    fi

    # 4. JetBrains (IDE settings)
    if [[ "$bundle_id" =~ jetbrains ]] || [[ "$app_name" =~ IntelliJ|PyCharm|WebStorm|GoLand|RubyMine|PhpStorm|CLion|DataGrip|Rider ]]; then
        for base in ~/Library/Application\ Support/JetBrains ~/Library/Caches/JetBrains ~/Library/Logs/JetBrains; do
            [[ -d "$base" ]] && while IFS= read -r -d '' d; do files_to_clean+=("$d"); done < <(command find "$base" -maxdepth 1 -name "${app_name}*" -print0 2> /dev/null)
        done
    fi

    # 5. Unity / Unreal / Godot
    [[ "$app_name" =~ Unity|unity ]] && [[ -d ~/Library/Unity ]] && files_to_clean+=("$HOME/Library/Unity")
    [[ "$app_name" =~ Unreal|unreal ]] && [[ -d ~/Library/Application\ Support/Epic ]] && files_to_clean+=("$HOME/Library/Application Support/Epic")
    [[ "$app_name" =~ Godot|godot ]] && [[ -d ~/Library/Application\ Support/Godot ]] && files_to_clean+=("$HOME/Library/Application Support/Godot")

    # 6. Tools
    if [[ "$bundle_id" =~ microsoft.*[vV][sS][cC]ode ]]; then
        [[ -d "$HOME/.vscode" ]] && files_to_clean+=("$HOME/.vscode")
        [[ -d "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt" ]] && files_to_clean+=("$HOME/Library/Caches/com.microsoft.VSCode.ShipIt")
        [[ -d "$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt" ]] && files_to_clean+=("$HOME/Library/Caches/com.microsoft.VSCodeInsiders.ShipIt")
    fi
    [[ "$app_name" =~ Docker ]] && [[ -d ~/.docker ]] && files_to_clean+=("$HOME/.docker")

    # 6.1 Maestro Studio
    if [[ "$bundle_id" == "com.maestro.studio" ]] || [[ "$lowercase_name" =~ maestro[[:space:]]*studio ]]; then
        [[ -d ~/.mobiledev ]] && files_to_clean+=("$HOME/.mobiledev")
    fi

    # 7. Raycast
    if [[ "$bundle_id" == "com.raycast.macos" ]]; then
        # Standard user directories
        local raycast_dirs=(
            "$HOME/Library/Application Support"
            "$HOME/Library/Application Scripts"
            "$HOME/Library/Containers"
        )
        for dir in "${raycast_dirs[@]}"; do
            [[ -d "$dir" ]] && while IFS= read -r -d '' p; do
                files_to_clean+=("$p")
            done < <(command find "$dir" -maxdepth 1 -type d -iname "*raycast*" -print0 2> /dev/null)
        done

        # Explicit Raycast container directories (hardcoded leftovers)
        [[ -d "$HOME/Library/Containers/com.raycast.macos.BrowserExtension" ]] && files_to_clean+=("$HOME/Library/Containers/com.raycast.macos.BrowserExtension")
        [[ -d "$HOME/Library/Containers/com.raycast.macos.RaycastAppIntents" ]] && files_to_clean+=("$HOME/Library/Containers/com.raycast.macos.RaycastAppIntents")

        # Cache (deeper search)
        [[ -d "$HOME/Library/Caches" ]] && while IFS= read -r -d '' p; do
            files_to_clean+=("$p")
        done < <(command find "$HOME/Library/Caches" -maxdepth 2 -type d -iname "*raycast*" -print0 2> /dev/null)

        # VSCode extension storage
        local vscode_global="$HOME/Library/Application Support/Code/User/globalStorage"
        [[ -d "$vscode_global" ]] && while IFS= read -r -d '' p; do
            files_to_clean+=("$p")
        done < <(command find "$vscode_global" -maxdepth 1 -type d -iname "*raycast*" -print0 2> /dev/null)
    fi

    # Output results
    if [[ ${#files_to_clean[@]} -gt 0 ]]; then
        printf '%s\n' "${files_to_clean[@]}"
    fi
    return 0
}

get_diagnostic_report_paths_for_app() {
    local app_path="$1"
    local app_name="$2"
    local directory="$3"
    local prefix=""
    local exec_name=""
    local nospace_name="${app_name// /}"

    [[ -z "$app_path" || -z "$app_name" || -z "$directory" ]] && return 0
    [[ ! -d "$directory" ]] && return 0

    if [[ -f "$app_path/Contents/Info.plist" ]]; then
        exec_name=$(defaults read "$app_path/Contents/Info.plist" CFBundleExecutable 2> /dev/null || echo "")
        if [[ -z "$exec_name" ]]; then
            exec_name=$(grep -A1 "CFBundleExecutable" "$app_path/Contents/Info.plist" 2> /dev/null | grep "<string>" | sed -n 's/.*<string>\([^<]*\)<\/string>.*/\1/p' | head -1)
        fi
    fi
    prefix="${exec_name:-$nospace_name}"
    [[ -z "$prefix" || ${#prefix} -lt 3 ]] && return 0

    local dir_abs
    dir_abs=$(cd "$directory" 2> /dev/null && pwd -P 2> /dev/null) || return 0
    while IFS= read -r -d '' f; do
        [[ -z "$f" ]] && continue
        local base
        base=$(basename "$f" 2> /dev/null)
        case "$base" in
            "$prefix".* | "$prefix"_* | "$prefix"-*) ;;
            *) continue ;;
        esac
        case "$base" in
            *.ips | *.crash | *.spin) ;;
            *) continue ;;
        esac
        printf '%s\n' "$f"
    done < <(
        find "$dir_abs" -maxdepth 1 -type f \
            \( -name "${prefix}.*" -o -name "${prefix}_*" -o -name "${prefix}-*" \) \
            -print0 2> /dev/null || true
    )
    return 0
}

# Locate system-level application files
find_app_system_files() {
    local bundle_id="$1"
    local app_name="$2"
    local -a system_files=()

    # Generate all naming variants (same as find_app_files for consistency)
    local nospace_name="${app_name// /}"
    local underscore_name="${app_name// /_}"
    local hyphen_name="${app_name// /-}"
    local lowercase_hyphen=$(echo "$hyphen_name" | tr '[:upper:]' '[:lower:]')

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
        "/Library/Extensions/$app_name.kext"
        "/Library/StartupItems/$app_name"
        "/Library/Logs/$app_name"
        "/Library/Logs/$bundle_id"
    )

    # Add all naming variants for apps with spaces in name
    if [[ ${#app_name} -gt 3 && "$app_name" =~ [[:space:]] ]]; then
        system_patterns+=(
            "/Library/Application Support/$nospace_name"
            "/Library/Caches/$nospace_name"
            "/Library/Logs/$nospace_name"
            "/Library/Application Support/$underscore_name"
            "/Library/Application Support/$hyphen_name"
            "/Library/Caches/$hyphen_name"
            "/Library/Caches/$lowercase_hyphen"
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
            done < <(command find "$base" -maxdepth 1 \( -name "*$app_name*.plist" \) -print0 2> /dev/null)
        done
    fi

    # Privileged Helper Tools and Receipts (special handling)
    # Only search with bundle_id if it's valid (not empty and not "unknown")
    if [[ -n "$bundle_id" && "$bundle_id" != "unknown" && ${#bundle_id} -gt 3 ]]; then
        [[ -d /Library/PrivilegedHelperTools ]] && while IFS= read -r -d '' helper; do
            system_files+=("$helper")
        done < <(command find /Library/PrivilegedHelperTools -maxdepth 1 \( -name "$bundle_id*" \) -print0 2> /dev/null)

        [[ -d /private/var/db/receipts ]] && while IFS= read -r -d '' receipt; do
            system_files+=("$receipt")
        done < <(command find /private/var/db/receipts -maxdepth 1 \( -name "*$bundle_id*" \) -print0 2> /dev/null)
    fi

    # Raycast system-level files
    if [[ "$bundle_id" == "com.raycast.macos" ]]; then
        [[ -d "/Library/Application Support" ]] && while IFS= read -r -d '' p; do
            system_files+=("$p")
        done < <(command find "/Library/Application Support" -maxdepth 1 -type d -iname "*raycast*" -print0 2> /dev/null)
    fi

    local receipt_files=""
    receipt_files=$(find_app_receipt_files "$bundle_id")

    local combined_files=""
    if [[ ${#system_files[@]} -gt 0 ]]; then
        combined_files=$(printf '%s\n' "${system_files[@]}")
    fi

    if [[ -n "$receipt_files" ]]; then
        if [[ -n "$combined_files" ]]; then
            combined_files+=$'\n'
        fi
        combined_files+="$receipt_files"
    fi

    if [[ -n "$combined_files" ]]; then
        printf '%s\n' "$combined_files" | sort -u
    fi
}

# Locate files using installation receipts (BOM)
find_app_receipt_files() {
    local bundle_id="$1"

    # Skip if no bundle ID
    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 0

    # Validate bundle_id format to prevent wildcard injection
    # Only allow alphanumeric characters, dots, hyphens, and underscores
    if [[ ! "$bundle_id" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        debug_log "Invalid bundle_id format: $bundle_id"
        return 0
    fi

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

                # Path traversal protection: reject paths containing ..
                if [[ "$clean_path" =~ \.\. ]]; then
                    debug_log "Rejected path traversal in BOM: $clean_path"
                    continue
                fi

                # Normalize path (remove duplicate slashes)
                clean_path=$(tr -s "/" <<< "$clean_path")

                # ------------------------------------------------------------------------
                # Safety check: restrict removal to trusted paths
                # ------------------------------------------------------------------------
                local is_safe=false

                # Whitelisted prefixes (exclude /Users, /usr, /opt)
                case "$clean_path" in
                    /Applications/*) is_safe=true ;;
                    /Library/Application\ Support/*) is_safe=true ;;
                    /Library/Caches/*) is_safe=true ;;
                    /Library/Logs/*) is_safe=true ;;
                    /Library/Preferences/*) is_safe=true ;;
                    /Library/LaunchAgents/*) is_safe=true ;;
                    /Library/LaunchDaemons/*) is_safe=true ;;
                    /Library/PrivilegedHelperTools/*) is_safe=true ;;
                    /Library/Extensions/*) is_safe=false ;;
                    *) is_safe=false ;;
                esac

                # Hard blocks
                case "$clean_path" in
                    /System/* | /usr/bin/* | /usr/lib/* | /bin/* | /sbin/* | /private/*) is_safe=false ;;
                esac

                if [[ "$is_safe" == "true" && -e "$clean_path" ]]; then
                    # Skip top-level directories
                    if [[ "$clean_path" == "/Applications" || "$clean_path" == "/Library" ]]; then
                        continue
                    fi

                    if declare -f should_protect_path > /dev/null 2>&1; then
                        if should_protect_path "$clean_path"; then
                            continue
                        fi
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

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        debug_log "[DRY RUN] Would terminate running app: $app_name"
        return 0
    fi

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
