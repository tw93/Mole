//
//  ProtectedApps.swift
//  Tonic
//
//  Protected app lists migrated from lib/core/app_protection.sh
//  System critical and data-protected application lists
//

import Foundation

/// Protected application manager
/// Migrated from Mole's lib/core/app_protection.sh
enum ProtectedApps {
    // MARK: - System Critical (never uninstall)

    /// Bundle IDs that are critical to system operation
    /// These apps should never be uninstalled
    static let systemCriticalBundles: Set<String> = [
        // System essentials
        "com.apple.SystemStatusServer",
        "com.apple.OSAnalyzer",
        "loginwindow",
        "dock",
        "systempreferences",
        "finder",
        "safari",

        // System Settings (macOS Sequoia)
        "com.apple.Settings",
        "com.apple.SystemSettings",
        "com.apple.controlcenter",
        "com.apple.backgroundtaskmanagement",
        "com.apple.loginitems",
        "com.apple.sharedfilelist",
        "com.apple.sfl",

        // Input methods
        "com.apple.inputmethod.*",
        "TextInputMenu",
        "TextInputSwitcher",

        // Third-party input methods (protected during cleanup)
        "com.tencent.inputmethod.QQInput",
        "com.sogou.inputmethod.*",
        "com.baidu.inputmethod.*",
        "com.googlecode.rimeime.*",
        "im.rime.*",
    ]

    // MARK: - Data Protected (protected during cleanup)

    /// Applications with sensitive user data
    /// Protected during cleanup but uninstall allowed
    static let dataProtectedBundles: Set<String> = [
        // Input Methods (protected during cleanup, uninstall allowed)
        "*.inputmethod",
        "*.InputMethod",
        "*IME",

        // System Utilities & Cleanup Tools
        "com.nektony.*",
        "com.macpaw.*",
        "com.freemacsoft.AppCleaner",
        "com.omnigroup.omnidisksweeper",
        "com.daisydiskapp.*",
        "com.tunabellysoftware.*",
        "com.grandperspectiv.*",
        "com.binaryfruit.*",

        // Password Managers & Security
        "com.1password.*",
        "com.agilebits.*",
        "com.lastpass.*",
        "com.dashlane.*",
        "com.bitwarden.*",
        "com.keepassx.*",
        "org.keepassx.*",
        "org.keepassxc.*",
        "com.authy.*",
        "com.yubico.*",

        // Development Tools - IDEs & Editors
        "com.jetbrains.*",
        "JetBrains*",
        "com.microsoft.VSCode",
        "com.visualstudio.code.*",
        "com.sublimetext.*",
        "com.sublimehq.*",
        "com.microsoft.VSCodeInsiders",
        "com.apple.dt.Xcode",
        "com.coteditor.CotEditor",
        "com.macromates.TextMate",
        "com.panic.Nova",
        "abnerworks.Typora",
        "com.uranusjr.macdown",

        // AI & LLM Tools
        "com.todesktop.*",
        "Cursor",
        "com.anthropic.claude*",
        "Claude",
        "com.openai.chat*",
        "ChatGPT",
        "com.ollama.ollama",
        "Ollama",
        "com.lmstudio.lmstudio",
        "LM Studio",
        "co.supertool.chatbox",
        "page.jan.jan",
        "com.huggingface.huggingchat",
        "Gemini",
        "com.perplexity.Perplexity",
        "com.drawthings.DrawThings",
        "com.divamgupta.diffusionbee",
        "com.exafunction.windsurf",
        "com.quora.poe.electron",
        "chat.openai.com.*",

        // Development Tools - Database Clients
        "com.sequelpro.*",
        "com.sequel-ace.*",
        "com.tinyapp.*",
        "com.dbeaver.*",
        "com.navicat.*",
        "com.mongodb.compass",
        "com.redis.RedisInsight",
        "com.pgadmin.pgadmin4",
        "com.eggerapps.Sequel-Pro",
        "com.valentina-db.Valentina-Studio",
        "com.dbvis.DbVisualizer",

        // Development Tools - API & Network
        "com.postmanlabs.mac",
        "com.konghq.insomnia",
        "com.CharlesProxy.*",
        "com.proxyman.*",
        "com.getpaw.*",
        "com.luckymarmot.Paw",
        "com.charlesproxy.charles",
        "com.telerik.Fiddler",
        "com.usebruno.app",

        // Network Proxy & VPN Tools
        "*clash*",
        "*Clash*",
        "com.nssurge.surge-mac",
        "*surge*",
        "*Surge*",
        "mihomo*",
        "*openvpn*",
        "*OpenVPN*",
        "net.openvpn.*",
        "*ShadowsocksX-NG*",
        "com.qiuyuzhou.*",
        "*v2ray*",
        "*V2Ray*",
        "*v2box*",
        "*V2Box*",
        "*nekoray*",
        "*sing-box*",
        "*OneBox*",
        "*hiddify*",
        "*Hiddify*",
        "*loon*",
        "*Loon*",
        "*quantumult*",
        "*tailscale*",
        "io.tailscale.*",
        "*zerotier*",
        "com.zerotier.*",
        "*1dot1dot1dot1*",
        "*cloudflare*warp*",
        "*nordvpn*",
        "*expressvpn*",
        "*protonvpn*",
        "*surfshark*",
        "*windscribe*",
        "*mullvad*",
        "*privateinternetaccess*",

        // Screensaver & Dynamic Wallpaper
        "*Aerial*",
        "*aerial*",
        "*Fliqlo*",
        "*fliqlo*",

        // Development Tools - Git & Version Control
        "com.github.GitHubDesktop",
        "com.sublimemerge",
        "com.torusknot.SourceTreeNotMAS",
        "com.git-tower.Tower*",
        "com.gitfox.GitFox",
        "com.github.Gitify",
        "com.fork.Fork",
        "com.axosoft.gitkraken",

        // Development Tools - Terminal & Shell
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "com.hyper.Hyper",
        "com.mizage.divvy",
        "com.fig.Fig",
        "dev.warp.Warp-Stable",
        "com.termius-dmg",

        // Development Tools - Docker & Virtualization
        "com.docker.docker",
        "com.getutm.UTM",
        "com.vmware.fusion",
        "com.parallels.desktop.*",
        "org.virtualbox.app.VirtualBox",
        "com.vagrant.*",
        "com.orbstack.OrbStack",

        // System Monitoring & Performance
        "com.bjango.istatmenus*",
        "eu.exelban.Stats",
        "com.monitorcontrol.*",
        "com.bresink.system-toolkit.*",
        "com.mediaatelier.MenuMeters",
        "com.activity-indicator.app",
        "net.cindori.sensei",

        // Window Management & Productivity
        "com.macitbetter.*",
        "com.hegenberg.*",
        "com.manytricks.*",
        "com.divisiblebyzero.*",
        "com.koingdev.*",
        "com.if.Amphetamine",
        "com.lwouis.alt-tab-macos",
        "net.matthewpalmer.Vanilla",
        "com.lightheadsw.Caffeine",
        "com.contextual.Contexts",
        "com.amethyst.Amethyst",
        "com.knollsoft.Rectangle",
        "com.knollsoft.Hookshot",
        "com.surteesstudios.Bartender",
        "com.gaosun.eul",
        "com.pointum.hazeover",

        // Launcher & Automation
        "com.runningwithcrayons.Alfred",
        "com.raycast.macos",
        "com.blacktree.Quicksilver",
        "com.stairways.keyboardmaestro.*",
        "com.manytricks.Butler",
        "com.happenapps.Quitter",
        "com.pilotmoon.scroll-reverser",
        "org.pqrs.Karabiner-Elements",
        "com.apple.Automator",

        // Note-Taking & Documentation
        "com.bear-writer.*",
        "com.typora.*",
        "com.ulyssesapp.*",
        "com.literatureandlatte.*",
        "com.dayoneapp.*",
        "notion.id",
        "md.obsidian",
        "com.logseq.logseq",
        "com.evernote.Evernote",
        "com.onenote.mac",
        "com.omnigroup.OmniOutliner*",
        "net.shinyfrog.bear",
        "com.goodnotes.GoodNotes",
        "com.marginnote.MarginNote*",
        "com.roamresearch.*",
        "com.reflect.ReflectApp",
        "com.inkdrop.*",

        // Design & Creative Tools
        "com.adobe.*",
        "com.bohemiancoding.*",
        "com.figma.*",
        "com.framerx.*",
        "com.zeplin.*",
        "com.invisionapp.*",
        "com.principle.*",
        "com.pixelmatorteam.*",
        "com.affinitydesigner.*",
        "com.affinityphoto.*",
        "com.affinitypublisher.*",
        "com.linearity.curve",
        "com.canva.CanvaDesktop",
        "com.maxon.cinema4d",
        "com.autodesk.*",
        "com.sketchup.*",

        // Communication & Collaboration
        "com.tencent.xinWeChat",
        "com.tencent.qq",
        "com.alibaba.DingTalkMac",
        "com.alibaba.AliLang.osx",
        "com.alibaba.alilang3.osx.ShipIt",
        "com.alibaba.AlilangMgr.QueryNetworkInfo",
        "us.zoom.xos",
        "com.microsoft.teams*",
        "com.slack.Slack",
        "com.hnc.Discord",
        "app.legcord.Legcord",
        "org.telegram.desktop",
        "ru.keepcoder.Telegram",
        "net.whatsapp.WhatsApp",
        "com.skype.skype",
        "com.cisco.webexmeetings",
        "com.ringcentral.RingCentral",
        "com.readdle.smartemail-Mac",
        "com.airmail.*",
        "com.postbox-inc.postbox",
        "com.tinyspeck.slackmacgap",

        // Task Management & Productivity
        "com.omnigroup.OmniFocus*",
        "com.culturedcode.*",
        "com.todoist.*",
        "com.any.do.*",
        "com.ticktick.*",
        "com.microsoft.to-do",
        "com.trello.trello",
        "com.asana.nativeapp",
        "com.clickup.*",
        "com.monday.desktop",
        "com.airtable.airtable",
        "notion.id",
        "com.linear.linear",

        // File Transfer & Sync
        "com.panic.transmit*",
        "com.binarynights.ForkLift*",
        "com.noodlesoft.Hazel",
        "com.cyberduck.Cyberduck",
        "io.filezilla.FileZilla",
        "com.apple.Xcode.CloudDocuments",
        "com.synology.*",

        // Cloud Storage & Backup
        "com.dropbox.*",
        "com.getdropbox.*",
        "*dropbox*",
        "ws.agile.*",
        "com.backblaze.*",
        "*backblaze*",
        "com.box.desktop*",
        "*box.desktop*",
        "com.microsoft.OneDrive*",
        "com.microsoft.SyncReporter",
        "*OneDrive*",
        "com.google.GoogleDrive",
        "com.google.keystone*",
        "*GoogleDrive*",
        "com.amazon.drive",
        "com.apple.bird",
        "com.apple.CloudDocs*",
        "com.displaylink.*",
        "com.fujitsu.pfu.ScanSnap*",
        "com.citrix.*",
        "org.xquartz.*",
        "us.zoom.updater*",
        "com.DigiDNA.iMazing*",
        "com.shirtpocket.*",
        "homebrew.mxcl.*",

        // Screenshot & Recording
        "com.cleanshot.*",
        "com.xnipapp.xnip",
        "com.reincubate.camo",
        "com.tunabellysoftware.ScreenFloat",
        "net.telestream.screenflow*",
        "com.techsmith.snagit*",
        "com.techsmith.camtasia*",
        "com.obsidianapp.screenrecorder",
        "com.kap.Kap",
        "com.getkap.*",
        "com.linebreak.CloudApp",
        "com.droplr.droplr-mac",

        // Media & Entertainment
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.podcasts",
        "com.apple.BKAgentService",
        "com.apple.iBooksX",
        "com.apple.iBooks",
        "com.apple.FinalCutPro",
        "com.apple.Motion",
        "com.apple.Compressor",
        "com.blackmagic-design.*",
        "com.colliderli.iina",
        "org.videolan.vlc",
        "io.mpv",
        "tv.plex.player.desktop",
        "com.netease.163music",

        // Web Browsers
        "Firefox",
        "org.mozilla.*",

        // License Management & App Stores
        "com.paddle.Paddle*",
        "com.setapp.DesktopClient",
        "com.devmate.*",
        "org.sparkle-project.Sparkle",
    ]

    // MARK: - Path Patterns

    /// Protected path patterns
    /// These paths should never be deleted during cleanup
    static let protectedPathPatterns: [String] = [
        // System-critical caches (CRITICAL - prevents blank panel bug)
        "*com.apple.systempreferences.cache*",
        "*com.apple.Settings.cache*",
        "*com.apple.controlcenter.cache*",
        "*com.apple.finder.cache*",
        "*com.apple.dock.cache*",

        // System Settings and Control Center
        "*com.apple.Settings*",
        "*com.apple.SystemSettings*",
        "*com.apple.controlcenter*",
        "*com.apple.finder*",
        "*com.apple.dock*",

        // Critical preference files
        "*/Library/Preferences/com.apple.dock.plist",
        "*/Library/Preferences/com.apple.finder.plist",
        "*/ByHost/com.apple.bluetooth.*",
        "*/ByHost/com.apple.wifi.*",

        // iCloud Drive
        "*/Library/Mobile Documents*",
        "*Mobile Documents*",

        // Notes cache
        "*com.apple.notes*",

        // Finder metadata sentinel
        "FINDER_METADATA",
    ]

    // MARK: - Protected App Categories

    /// Categorized protected apps for UI display
    enum ProtectedCategory: String, CaseIterable {
        case systemUtilities = "System Utilities"
        case passwordManagers = "Password Managers"
        case developmentTools = "Development Tools"
        case aiTools = "AI & LLM Tools"
        case terminal = "Terminal & Shell"
        case virtualization = "Virtualization"
        case monitoring = "System Monitoring"
        case windowManagement = "Window Management"
        case launchers = "Launchers & Automation"
        case notes = "Note-Taking"
        case creative = "Design & Creative"
        case communication = "Communication"
        case productivity = "Productivity"
        case fileTransfer = "File Transfer & Sync"
        case cloudStorage = "Cloud Storage"
        case screenshot = "Screenshot & Recording"
        case vpn = "VPN & Proxy"
        case browser = "Web Browsers"

        var icon: String {
            switch self {
            case .systemUtilities: return "wrench.and.screwdriver"
            case .passwordManagers: return "lock.shield"
            case .developmentTools: return "hammer"
            case .aiTools: return "brain"
            case .terminal: return "terminal"
            case .virtualization: return "server.rack"
            case .monitoring: return "gauge"
            case .windowManagement: return "rectangle.split.3x3"
            case .launchers: return "command"
            case .notes: return "note.text"
            case .creative: return "paintbrush"
            case .communication: return "message"
            case .productivity: return "checkmark.circle"
            case .fileTransfer: return "arrow.doc"
            case .cloudStorage: return "icloud"
            case .screenshot: return "camera"
            case .vpn: return "shield.lefthalf.filled"
            case .browser: return "globe"
            }
        }
    }

    // MARK: - Helper Methods

    /// Check if a bundle ID is protected from uninstallation
    static func isProtectedFromUninstall(_ bundleId: String) -> Bool {
        return systemCriticalBundles.contains { pattern in
            bundleId.matchesWildcard(pattern: pattern)
        }
    }

    /// Check if a bundle ID should have its data protected during cleanup
    static func isDataProtected(_ bundleId: String) -> Bool {
        return systemCriticalBundles.contains { pattern in
            bundleId.matchesWildcard(pattern: pattern)
        } || dataProtectedBundles.contains { pattern in
            bundleId.matchesWildcard(pattern: pattern)
        }
    }

    /// Check if a path is protected from deletion
    static func isPathProtected(_ path: String) -> Bool {
        let lowercased = path.lowercased()

        // Check system critical paths
        if lowercased.contains("systemsettings") ||
           lowercased.contains("systempreferences") ||
           lowercased.contains("controlcenter") ||
           lowercased.contains("com.apple.settings") ||
           lowercased.contains("com.apple.notes") {
            return true
        }

        // Check protected patterns
        for pattern in protectedPathPatterns {
            if path.matchesWildcard(pattern: pattern) {
                return true
            }
        }

        // Check against bundle IDs
        for pattern in systemCriticalBundles.union(dataProtectedBundles) {
            if path.matchesWildcard(pattern: pattern) {
                return true
            }
        }

        return false
    }

    /// Get protected category for a bundle ID
    static func getProtectedCategory(for bundleId: String) -> ProtectedCategory? {
        let lowercased = bundleId.lowercased()

        if lowercased.contains("1password") || lowercased.contains("bitwarden") || lowercased.contains("lastpass") {
            return .passwordManagers
        } else if lowercased.contains("jetbrains") || lowercased.contains("xcode") || lowercased.contains("vscode") {
            return .developmentTools
        } else if lowercased.contains("claude") || lowercased.contains("cursor") || lowercased.contains("chatgpt") || lowercased.contains("ollama") {
            return .aiTools
        } else if lowercased.contains("iterm") || lowercased.contains("kitty") || lowercased.contains("alacritty") {
            return .terminal
        } else if lowercased.contains("docker") || lowercased.contains("vmware") || lowercased.contains("parallels") {
            return .virtualization
        } else if lowercased.contains("istat") || lowercased.contains("stats") || lowercased.contains("monitor") {
            return .monitoring
        } else if lowercased.contains("rectangle") || lowercased.contains("bettertouch") || lowercased.contains("amethyst") {
            return .windowManagement
        } else if lowercased.contains("alfred") || lowercased.contains("raycast") || lowercased.contains("keyboardmaestro") {
            return .launchers
        } else if lowercased.contains("bear") || lowercased.contains("obsidian") || lowercased.contains("notion") {
            return .notes
        } else if lowercased.contains("adobe") || lowercased.contains("sketch") || lowercased.contains("figma") {
            return .creative
        } else if lowercased.contains("slack") || lowercased.contains("discord") || lowercased.contains("zoom") {
            return .communication
        } else if lowercased.contains("dropbox") || lowercased.contains("onedrive") || lowercased.contains("icloud") {
            return .cloudStorage
        } else if lowercased.contains("clash") || lowercased.contains("surge") || lowercased.contains("tailscale") {
            return .vpn
        } else if lowercased.contains("firefox") || lowercased.contains("chrome") || lowercased.contains("safari") {
            return .browser
        }

        return nil
    }
}

// MARK: - String Wildcard Matching

extension String {
    /// Check if string matches a wildcard pattern (* for any characters)
    func matchesWildcard(pattern: String) -> Bool {
        // Fast path: exact match
        if self == pattern { return true }

        // Fast path: no wildcard in pattern
        if !pattern.contains("*") {
            return self == pattern
        }

        // Convert wildcard pattern to regex
        let regexPattern = "^" + pattern
            .replacingOccurrences(of: ".", with: "\\.")  // Escape dots
            .replacingOccurrences(of: "*", with: ".*")    // * becomes .*
            .replacingOccurrences(of: "?", with: ".")     // ? becomes .
            + "$"

        guard let regex = try? NSRegularExpression(pattern: regexPattern, options: [.caseInsensitive]) else {
            return false
        }

        let range = NSRange(location: 0, length: self.utf16.count)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
}

