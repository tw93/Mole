#!/bin/bash
# Mole - Application Protection Data
# Static bundle ID and pattern lists, sourced by lib/core/app_protection.sh.
# Keep this file data-only. Logic belongs in app_protection.sh.

set -euo pipefail

if [[ -n "${MOLE_APP_PROTECTION_DATA_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_APP_PROTECTION_DATA_LOADED=1

# Application Management

# Detailed list for uninstall protection (lazy-loaded into SYSTEM_CRITICAL_REGEX).
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

# Vendor-managed security / MDM apps must use their official uninstallers.
# Shape: vendor|bundle-prefixes-comma-separated|name-fragments-comma-separated
readonly OFFICIAL_UNINSTALLER_RULES=(
    "ESET|com.eset.|eset management agent,eset remote administrator agent,eset endpoint security,eset endpoint antivirus"
    "Jamf|com.jamf.,com.jamfsoftware.|jamf connect,jamf protect,jamf self service"
    "CrowdStrike|com.crowdstrike.|crowdstrike,falcon"
    "SentinelOne|com.sentinelone.,com.sentinel-labs.|sentinelone,sentinel agent"
    "GlobalProtect|com.paloaltonetworks.|globalprotect"
    "Cisco|com.cisco.anyconnect,com.cisco.secureclient|cisco secure client,cisco anyconnect"
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
    "com.openai.codex"
    "Codex"
    "codex-runtimes"
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
    "org.amnezia.*"
    "*amnezia*"
    "*Amnezia*"
    "com.wireguard.*"
    "*wireguard*"
    "*WireGuard*"

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
    "dev.orbstack.OrbStack"
    "dev.orbstack.*"
    "dev.kdrag0n.MacVirt"
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
    "com.avid.mediacomposer*"
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
    "com.native-instruments.*"
    "com.fabfilter.*"
    "com.paceap.*"
    "com.izotope.*"
    "iZotope"
    "com.lasersoft-imaging.*"
    "app.cotypist.Cotypist"

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

    # Remote Desktop / Remote Access
    "org.chromium.chromoting*"
    "com.google.chrome_remote_desktop*"
    "com.teamviewer.*"
    "com.realvnc.*"
    "com.logmein.*"
    "com.anydesk.*"

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

    # Scientific & Professional Software
    "com.crowdstrike.*"
    "com.kolide.*"
    "com.sas.*"
    "com.mathworks.*"
    "com.ibm.spss.*"
    "com.wolfram.*"
    "com.stata.*"
    "org.rstudio.*"
    "com.tableausoftware.*"

    # License & App Stores
    "com.paddle.Paddle*"
    "com.quicken.*"
    "com.setapp.DesktopClient"
    "com.devmate.*"
    "org.sparkle-project.Sparkle*"
)

# Dotdir / XDG state directory names that belong to standalone CLI tools
# shipped independently of any same-named GUI app. find_app_files() must not
# propose these for deletion even when uninstalling a GUI app whose display
# name collides, because the CLI tool is a separate product.
#
# Issue #993: uninstalling Claude.app wiped ~/.claude (Claude Code CLI);
# uninstalling OpenCode.app wiped ~/.local/share/opencode and the opencode
# CLI binary. Case-insensitive APFS makes the collision worse: $HOME/.Claude
# (built from app_name="Claude") aliases to $HOME/.claude.
#
# Match is lowercase + leading-dot-stripped, scoped to $HOME, $HOME/.config,
# $HOME/.local/share, $HOME/.cache. Add new entries as the AI-tool ecosystem
# produces more GUI/CLI namesakes.
readonly INDEPENDENT_CLI_DOTDIR_NAMES=(
    "claude"   # Claude Code CLI (Claude Desktop uses ~/Library/Application Support/Claude)
    "opencode" # sst/opencode CLI
    "codex"    # OpenAI codex CLI (Codex Desktop uses ~/Library/Application Support/Codex)
    "gemini"   # Google gemini CLI
)
