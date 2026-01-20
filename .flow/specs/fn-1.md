# Tonic For Mac - Product Development Specification

## Overview

**Tonic For Mac** is the ultimate, all-in-one macOS management utility that consolidates the best features of CleanMyMac, AppCleaner, DaisyDisk, and iStat Menus into a single, cohesive application with exceptional UX. Built upon the functional core of the open-source **Mole** utility, Tonic delivers a slick, modern interface with fluid animations and superior user experience.

**Vision:** Create the single, indispensable tool for Mac users seeking to maintain, optimize, and monitor their systems.

**Monetization:** Freemium model - Tonic Basic (free) drives adoption, Tonic Pro (premium) unlocks advanced features.

## Module Structure

| Module | Competitor | Feature Focus |
|--------|-----------|---------------|
| **1. System Cleanup** | CleanMyMac, Mole | Smart Scan, Deep Cleaning, Maintenance |
| **2. App Management** | AppCleaner, CleanMyMac | Smart Uninstaller, App Manager, Updater |
| **3. Disk Analysis** | DaisyDisk | Visual Disk Map, Hidden Space, Cloud Scan |
| **4. Live Monitoring** | iStat Menus, Mole | Menu Bar Widgets, Dashboard, Notifications |
| **5. Developer Tools** | Mole | Project Purge, Docker/VM Cleanup |

## Freemium Feature Split

| Feature | Tonic Basic (Free) | Tonic Pro ($29-49 one-time) |
|---------|-------------------|----------------------------|
| **System Cleanup** | Basic cache/log cleaning (user only) | Deep system cleaning, admin files |
| **App Management** | Smart Uninstaller (basic) | App Updater, App Manager |
| **Disk Analysis** | Basic disk map (user files) | Hidden space scan, cloud/network scan |
| **Monitoring** | CPU, Memory, Network widgets | All widgets (GPU, sensors), smart notifications |
| **Developer Tools** | N/A | Project purge, Docker/VM cleanup |
| **UX** | Slick UI, animations | Advanced customization |

---

# ARCHITECTURE

## Tech Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| **UI Framework** | SwiftUI | Modern, performant, native animations |
| **Core Logic** | Swift | Type-safe, fast, Apple ecosystem |
| **Background Processing** | Swift Concurrency (async/await) | Structured concurrency, safe |
| **Privileged Operations** | SMJobBless Helper Tool | Apple's blessed pattern |
| **Updates** | Sparkle 2.x | Industry standard for direct distribution |
| **Licensing** | RevenueCat or custom | Subscription/purchase management |
| **Visualization** | Custom SwiftUI + Core Animation | 60fps animations, smooth zoom |
| **Data Persistence** | UserDefaults + CoreData | Settings, scan cache, history |
| **Networking** | URLSession | Update checks, cloud APIs |

## App Structure

```
Tonic.app
├── Contents/
│   ├── MacOS/
│   │   ├── Tonic                    # Main app (SwiftUI)
│   │   └── TonicHelper              # Privileged helper (XPC)
│   ├── Library/
│   │   ├── LoginItems/
│   │   │   └── TonicMenuApp.app     # Menu bar widget (standalone)
│   │   └── XPCServices/
│   │       └── com.tonic.helper.xpc # Privileged operations
│   ├── Resources/
│   │   ├── Assets.xcassets          # Images, colors, SF Symbols
│   │   └── Licensing.plist          # RevenueCat config
│   └── SharedFrameworks/
│       └── TonicCore.framework       # Shared code (helper + main)
```

## Component Hierarchy

```
TonicApp
├── Services
│   ├── ScanService                  # Orchestrates all scans
│   ├── CleanupService               # Manages deletion operations
│   ├── HelperService                # XPC communication
│   ├── LicenseService               # Freemium gating
│   ├── NotificationService           # User notifications
│   └── PersistenceService           # Data storage
├── Models
│   ├── ScanResult                   # Scan data structures
│   ├── AppState                     # Global app state
│   ├── Preferences                  # User settings
│   └── LicenseState                 # Pro/Free status
├── Views
│   ├── DashboardView                # Main dashboard
│   ├── ScanView                     # Scan progress/results
│   ├── CleanupView                  # Review and clean
│   ├── DiskMapView                  # Visual disk map
│   ├── AppsView                     # App management
│   ├── MonitorView                  # System monitoring
│   ├── SettingsView                 # Preferences
│   └── OnboardingView               # First-run experience
└── MenuBar
    ├── MenuBarWidget                # Status item
    ├── MenuBarDropdown              # Click handler
    └── WidgetViews                  # Individual widgets
```

## State Management

Using `@Observable` (SwiftUI Observation framework):

```swift
@Observable
class AppState {
    var scanResults: ScanResults?
    var isScanning: Bool = false
    var healthScore: HealthScore = .good
    var licenseStatus: LicenseStatus = .free

    // Modules availability based on license
    var isPro: Bool { licenseStatus == .pro }

    // Service dependencies
    let scanService: ScanService
    let cleanupService: CleanupService
    let helperService: HelperService
    let licenseService: LicenseService
}
```

## Error Handling Strategy

```swift
enum TonicError: LocalizedError {
    case helperNotInstalled
    case permissionDenied(String)
    case scanFailed(underlying: Error)
    case deletionFailed(paths: [String])
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .helperNotInstalled:
            return "Helper tool not installed. Please complete onboarding."
        case .permissionDenied(let resource):
            return "Permission denied: \(resource)"
        case .scanFailed(let error):
            return "Scan failed: \(error.localizedDescription)"
        case .deletionFailed(let paths):
            return "Could not delete some files: \(paths.joined(separator: ", "))"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .helperNotInstalled:
            return "Run onboarding to install helper tool"
        case .permissionDenied:
            return "Grant Full Disk Access in System Settings"
        default:
            return nil
        }
    }
}
```

---

# MODULE 1: SYSTEM CLEANUP (C-1xx)

## Product Requirements

### C-101: Smart Scan

**User Story:** As a casual user, I want a single button that scans my Mac and tells me what needs attention.

**User Flow:**
1. User clicks "Smart Scan" on dashboard
2. Progress indicator shows scan progress (with category labels)
3. Results summary appears with Health Score
4. User can review each category
5. User clicks "Clean All" or reviews individual items
6. Confirmation dialog shows space to be reclaimed
7. Progress shows cleanup
8. Success notification with space reclaimed

**Acceptance Criteria:**
- Scan completes in <30 seconds
- Health Score accurately reflects system state
- Results grouped by category (Junk, Performance, Apps, Privacy)
- Color-coded severity (green/yellow/red)
- "Clean All" resolves all safe issues

**Technical Specifications:**

```swift
// Data Models
struct SmartScanResult {
    let healthScore: Int // 0-100
    let junkFiles: JunkCategory
    let performanceIssues: PerformanceCategory
    let appIssues: AppCategory
    let privacyIssues: PrivacyCategory
    let timestamp: Date
}

struct JunkCategory {
    let caches: [ScanItem]
    let logs: [ScanItem]
    let downloads: [ScanItem]
    let trash: [ScanItem]
    let totalSize: Int64

    var severity: ScanSeverity {
        switch totalSize {
        case 0..<1_000_000_000: return .good      // <1GB
        case 1_000_000_000..<5_000_000_000: return .warning  // 1-5GB
        default: return .critical                 // >5GB
        }
    }
}

struct ScanItem {
    let path: String
    let size: Int64
    let type: ScanItemType
    let description: String
    var selected: Bool = true
}

enum ScanSeverity {
    case good      // Green, 80-100
    case warning   // Yellow, 50-79
    case critical  // Red, 0-49
}
```

**Scan Implementation:**

```swift
class SmartScanService {
    func scan() async throws -> SmartScanResult {
        async let junk = scanJunk()
        async let performance = scanPerformance()
        async let apps = scanApps()
        async let privacy = scanPrivacy()

        let (junkResult, perfResult, appsResult, privacyResult) =
            try await (junk, performance, apps, privacy)

        let score = calculateHealthScore(
            junk: junkResult,
            performance: perfResult,
            apps: appsResult,
            privacy: privacyResult
        )

        return SmartScanResult(
            healthScore: score,
            junkFiles: junkResult,
            performanceIssues: perfResult,
            appIssues: appsResult,
            privacyIssues: privacyResult,
            timestamp: Date()
        )
    }

    private func scanJunk() async throws -> JunkCategory {
        // Scan user caches
        let cachePaths = [
            "~/Library/Caches",
            "~/Library/Application Support/*/Cache",
        ]

        var items: [ScanItem] = []
        for path in cachePaths {
            items.append(contentsOf: try await scanDirectory(
                path: path.expandTilde,
                pattern: "*"
            ))
        }

        // Scan logs
        let logPaths = [
            "~/Library/Logs",
            "~/Library/Logs/*",
            "/var/log",  // Requires helper
        ]

        // Scan downloads
        let downloadsPath = "~/Downloads".expandTilde
        let oldFiles = try await findOldFiles(
            path: downloadsPath,
            olderThan: 90.days
        )

        // Scan trash
        let trashItems = try await scanTrash()

        return JunkCategory(
            caches: items.filter { $0.type == .cache },
            logs: items.filter { $0.type == .log },
            downloads: oldFiles,
            trash: trashItems,
            totalSize: items.reduce(0) { $0 + $1.size }
        )
    }
}
```

**File References:**
- `lib/clean/apps.sh` - Application cache patterns
- `lib/clean/app_caches.sh` - Browser cache patterns
- `lib/clean/caches.sh` - System cache patterns
- `lib/clean/user.sh` - User data patterns

---

### C-102: Deep Cleaning

**User Story:** As a power user, I want to selectively clean specific categories of junk files.

**Technical Specifications:**

```swift
enum CleanCategory {
    case browserCaches
    case systemCaches
    case applicationCaches
    case logs
    case downloads
    case trash
    case localizationFiles  // Remove .lproj not in user's language
    case developerCaches   // Pro feature
}

class DeepCleanService {
    private let helper: HelperService

    func scan(category: CleanCategory) async throws -> [ScanItem] {
        switch category {
        case .browserCaches:
            return try await scanBrowserCaches()
        case .systemCaches:
            return try await helper.scanSystemCaches()  // Requires helper
        case .applicationCaches:
            return try await scanAppCaches()
        case .logs:
            return try await scanLogs()
        case .downloads:
            return try await scanDownloads()
        case .trash:
            return try await scanTrash()
        case .localizationFiles:
            return try await scanLocalizationFiles()
        case .developerCaches:
            return try await scanDeveloperCaches()
        }
    }

    func clean(items: [ScanItem]) async throws -> CleanupResult {
        // Group by helper-required
        let (userItems, helperItems) = items.partition { item in
            item.path.starts(with: "/System") ||
            item.path.starts(with: "/Library")
        }

        // Delete user-level items
        for item in userItems {
            try FileManager.default.removeItem(atPath: item.path)
        }

        // Delete system-level items via helper
        let helperPaths = helperItems.map { $0.path }
        try await helper.deleteFiles(helperPaths)

        return CleanupResult(
            itemsDeleted: items.count,
            spaceReclaimed: items.reduce(0) { $0 + $1.size }
        )
    }
}
```

**Safety Mechanisms:**

```swift
class SafetyValidator {
    static let protectedPatterns = [
        "/System",
        "/Library/Apple",
        "/Library/Application Support/Apple",
        "/usr",
        "/bin",
        "/sbin",
    ]

    static let protectedApps = [
        "com.apple.finder",
        "com.apple.systempreferences",
        // From lib/core/app_protection.sh
    ]

    func validate(item: ScanItem) -> Bool {
        // Check path protection
        for pattern in Self.protectedPatterns {
            if item.path.hasPrefix(pattern) {
                return false
            }
        }

        // Check file type safety
        let ext = URL(fileURLWithPath: item.path).pathExtension.lowercased()
        if ["app", "framework", "kext"].contains(ext) {
            return false
        }

        return true
    }
}
```

---

### C-103: Trash & File Management

**Technical Specifications:**

```swift
struct TrashBin {
    let path: String
    let size: Int64
    let itemCount: Int
    let volumeName: String
}

class TrashService {
    func scanTrashBins() async throws -> [TrashBin] {
        var bins: [TrashBin] = []

        // User trash
        bins.append(TrashBin(
            path: "~/.Trash".expandTilde,
            size: try await directorySize("~/.Trash".expandTilde),
            itemCount: try await fileCount("~/.Trash".expandTilde),
            volumeName: "Macintosh HD"
        ))

        // External volumes
        let volumes = try await getExternalVolumes()
        for volume in volumes {
            let trashPath = "\(volume)/.Trashes/\(getUID())"
            if FileManager.default.fileExists(atPath: trashPath) {
                bins.append(TrashBin(
                    path: trashPath,
                    size: try await directorySize(trashPath),
                    itemCount: try await fileCount(trashPath),
                    volumeName: (volume as NSString).lastPathComponent
                ))
            }
        }

        return bins
    }

    func secureDelete(_ path: String, passes: Int = 3) async throws {
        // DOD 5220.22-M standard: 3 passes
        // Pattern: 0x00, 0xFF, random

        let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        let fileSize = try FileManager.default.attributesOfItem(atPath: path)[.size] as! Int64

        for pass in 1...passes {
            try fileHandle.seek(toOffset: 0)
            let pattern: UInt8 = pass == 3 ? .random : (pass == 1 ? 0x00 : 0xFF)
            let buffer = Data(repeating: pattern, count: Int(fileSize))
            try fileHandle.write(contentsOf: buffer)
            try fileHandle.synchronize()
        }

        try fileHandle.close()
        try FileManager.default.removeItem(atPath: path)
    }
}

struct LargeFileCriteria {
    var minSize: Int64 = 100 * 1024 * 1024  // 100MB default
    var minAge: TimeInterval = 365 * 24 * 3600  // 1 year default
    var includePaths: [String] = ["~", "~/Downloads", "~/Documents"]
    var excludePatterns: [String] = [".app", ".photoslibrary"]
}

class LargeFileScanner {
    func findLargeFiles(criteria: LargeFileCriteria) async throws -> [URL] {
        var results: [URL] = []

        for basePath in criteria.includePaths {
            let expandedPath = basePath.expandTilde
            let enumerator = FileManager.default.enumerator(
                atPath: expandedPath,
                includingPropertiesForKeys: [.fileSizeKey, .modificationDateKey]
            )

            for case let item as URL in enumerator {
                guard let resourceValues = try item.resourceValues(
                    forKeys: [.fileSizeKey, .modificationDateKey, .isDirectoryKey]
                ) else { continue }

                if resourceValues.isDirectory == true { continue }

                guard let size = resourceValues.fileSize,
                      size >= criteria.minSize else { continue }

                guard let modDate = resourceValues.modificationDate,
                      Date().timeIntervalSince(modDate) >= criteria.minAge else { continue }

                // Check exclusions
                let path = item.path
                if criteria.excludePatterns.contains(where: { path.contains($0) }) {
                    continue
                }

                results.append(item)
            }
        }

        return results.sorted { $0.resourceValues(forKeys: [.fileSizeKey]) ?? [] }
    }
}
```

---

### C-104: Maintenance

**Technical Specifications:**

```swift
enum MaintenanceTask {
    case freeMemory
    case rebuildSpotlightIndex
    case repairDiskPermissions
    case flushDNSCache
    case rebuildLaunchServices
    case runPeriodicScripts
}

struct MaintenanceResult {
    let task: MaintenanceTask
    let success: Bool
    let output: String
    let before: SystemMetrics
    let after: SystemMetrics
}

class MaintenanceService {
    private let helper: HelperService

    func run(_ tasks: [MaintenanceTask]) async throws -> [MaintenanceResult] {
        var results: [MaintenanceResult] = []

        let before = try await captureMetrics()

        for task in tasks {
            let result = try await runTask(task, before: before)
            results.append(result)
        }

        return results
    }

    private func runTask(_ task: MaintenanceTask, before: SystemMetrics) async throws -> MaintenanceResult {
        var output = ""
        var success = false

        switch task {
        case .freeMemory:
            // Purge inactive memory
            output = try await shell("purge")
            success = true

        case .rebuildSpotlightIndex:
            let volume = "/"
            output = try await shell("mdutil -E \(volume)")
            success = true

        case .repairDiskPermissions:
            // Requires helper
            output = try await helper.repairDiskPermissions()
            success = true

        case .flushDNSCache:
            output = try await shell("sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder")
            success = true

        case .rebuildLaunchServices:
            // Run LSRegister if available (older macOS)
            // On modern macOS: /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -seed -r
            output = try await shell("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -seed -r /")
            success = true

        case .runPeriodicScripts:
            // Daily, weekly, monthly scripts
            output = try await helper.runPeriodicScripts()
            success = true
        }

        let after = try await captureMetrics()

        return MaintenanceResult(
            task: task,
            success: success,
            output: output,
            before: before,
            after: after
        )
    }
}
```

---

# MODULE 2: APP MANAGEMENT (A-2xx)

## Product Requirements

### A-201: Smart Uninstaller

**User Story:** As a user, I want to completely remove an app by dragging it to a drop zone, knowing all related files will be deleted too.

**User Flow:**
1. User drags app from Finder to Tonic's uninstall drop zone
2. App is analyzed for related files
3. Review screen shows all files found with sizes
4. User confirms deletion
5. App and all related files are moved to Trash
6. Success notification shown

**Technical Specifications:**

```swift
struct AppMetadata {
    let bundleID: String
    let name: String
    let version: String
    let icon: NSImage
    let path: String
    let size: Int64
    let lastUsed: Date?
    let installDate: Date?

    // Related files to delete
    var relatedFiles: [URL] = []
}

struct RelatedFileLocation {
    enum LocationType {
        case applicationSupport
        case caches
        case preferences
        case cookies
        case savedState
        case containers
        case logs
        case launchAgents
        case launchDaemons
    }

    let type: LocationType
    let path: String
    let size: Int64
}

class AppUninstaller {
    func analyzeApp(at path: String) async throws -> AppMetadata {
        let appURL = URL(fileURLWithPath: path)

        // Read Info.plist
        guard let infoPlist = URL(fileURLWithPath: path)
            .appendingPathComponent("Contents/Info.plist")
            .propertiesFromPlist() as? [String: Any] else {
            throw UninstallerError.invalidApp
        }

        let bundleID = infoPlist["CFBundleIdentifier"] as? String ?? ""
        let name = infoPlist["CFBundleDisplayName"] as? String
                ?? infoPlist["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent
        let version = infoPlist["CFBundleShortVersionString"] as? String
                  ?? infoPlist["CFBundleVersion"] as? String ?? ""

        // Get icon
        let icon = getAppIcon(from: appURL)

        // Calculate size
        let size = try await directorySize(path)

        // Find related files
        let relatedFiles = try await findRelatedFiles(for: bundleID, appName: name)

        return AppMetadata(
            bundleID: bundleID,
            name: name,
            version: version,
            icon: icon,
            path: path,
            size: size,
            lastUsed: getLastUsed(for: bundleID),
            installDate: getInstallDate(for: path),
            relatedFiles: relatedFiles
        )
    }

    private func findRelatedFiles(for bundleID: String, appName: String) async throws -> [URL] {
        var files: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Search locations
        let searchPaths: [(String, RelatedFileLocation.LocationType)] = [
            ("~/Library/Application Support", .applicationSupport),
            ("~/Library/Caches", .caches),
            ("~/Library/Preferences", .preferences),
            ("~/Library/Cookies", .cookies),
            ("~/Library/Saved Application State", .savedState),
            ("~/Library/Containers", .containers),
            ("~/Library/Logs", .logs),
            ("~/Library/LaunchAgents", .launchAgents),
        ]

        for (base, type) in searchPaths {
            let basePath = base.expandTilde
            guard let enumerator = FileManager.default.enumerator(
                atPath: basePath,
                includingPropertiesForKeys: nil
            ) else { continue }

            for case let file as URL in enumerator {
                let fileName = file.lastPathComponent
                let fileNameWithoutExt = (fileName as NSString).deletingPathExtension

                if fileName.contains(bundleID) ||
                   fileNameWithoutExt.contains(bundleID) ||
                   fileName.contains(appName) {
                    files.append(file)
                }
            }
        }

        // Check Homebrew
        if isBrewCask(bundleID) {
            if let brewInfo = try await shell("brew info --cask \(bundleID)") {
                // It's a Homebrew app
            }
        }

        return files
    }

    func uninstall(_ app: AppMetadata) async throws -> UninstallResult {
        // 1. Check if running
        if isAppRunning(app.bundleID) {
            try await quitApp(app.bundleID)
        }

        // 2. Remove login items
        try await removeLoginItems(for: app.bundleID)

        // 3. Move to trash (not delete immediately)
        for file in [URL(fileURLWithPath: app.path)] + app.relatedFiles {
            try FileManager.default.trashItem(at: file)
        }

        // 4. Rebuild LaunchServices database
        try await rebuildLaunchServices()

        return UninstallResult(
            appName: app.name,
            filesMovedToTrash: 1 + app.relatedFiles.count,
            spaceReclaimed: app.size + app.relatedFiles.reduce(0) {
                try! FileManager.default.attributesOfItem(atPath: $0.path)[.size] as! Int64
            }
        )
    }
}
```

**File References:**
- `bin/uninstall.sh:1-587` - Complete uninstall logic
- `lib/uninstall/batch.sh:169-641` - Batch operations
- `lib/core/app_protection.sh` - Protected apps list

---

### A-202: App Manager

**Technical Specifications:**

```swift
enum AppCategory {
    case all
    case applications        // /Applications
    case appStore           // Installed via Mac App Store
    case thirdParty         // Direct download, Homebrew
    case unsupported        // 32-bit apps
    case unused             // Not opened in >6 months
    case large              // >1GB
    case system             // Apple system apps
    case powerUser          // Dev tools, utilities
    case games              // Game category
}

struct AppListFilter {
    var category: AppCategory = .all
    var searchTerm: String = ""
    var sortBy: SortOption = .name
    var sortAscending: Bool = true

    enum SortOption {
        case name
        case size
        case lastUsed
        case installDate
    }
}

class AppManager {
    func scanApplications() async throws -> [AppMetadata] {
        var apps: [AppMetadata] = []

        // Scan /Applications
        let appsPath = "/Applications"
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: appsPath,
            includingPropertiesForKeys: nil
        )

        for case let url as URL in contents {
            guard url.pathExtension == "app" else { continue }

            do {
                let app = try await analyzeApp(at: url.path)
                apps.append(app)
            } catch {
                continue  // Skip invalid apps
            }
        }

        // Scan user's Applications
        let userApps = "~/Applications".expandTilde
        if FileManager.default.fileExists(atPath: userApps) {
            // Scan user apps too
        }

        return apps
    }

    func categorize(_ apps: [AppMetadata]) -> [AppCategory: [AppMetadata]] {
        var categorized: [AppCategory: [AppMetadata]] = [:]

        for app in apps {
            // 32-bit check
            if is32Bit(app) {
                categorized[.unsupported, default: []].append(app)
            }

            // Unused check
            if let lastUsed = app.lastUsed,
               Date().timeIntervalSince(lastUsed) > 180 * 24 * 3600 {  // 6 months
                categorized[.unused, default: []].append(app)
            }

            // Large check
            if app.size > 1_000_000_000 {  // 1GB
                categorized[.large, default: []].append(app)
            }
        }

        return categorized
    }

    private func is32Bit(_ app: AppMetadata) -> Bool {
        // Check arch via `file` command or `otool`
        if let output = try? shell("file \(app.path)") {
            return output.contains("(for architecture i386)") &&
                   !output.contains("x86_64") &&
                   !output.contains("arm64")
        }
        return false
    }
}
```

---

### A-203: App Updater

**Technical Specifications:**

```swift
struct UpdateInfo {
    let app: AppMetadata
    let currentVersion: String
    let latestVersion: String
    let downloadURL: URL?
    let releaseNotes: String?
    let size: Int64?
    let source: UpdateSource
}

enum UpdateSource {
    case appStore
    case homebrew
    case directDownload
    case sparkle
}

class AppUpdateService {
    private let session = URLSession.shared

    func checkForUpdates() async throws -> [UpdateInfo] {
        var updates: [UpdateInfo] = []

        // Check Homebrew casks
        let brewUpdates = try await checkHomebrewUpdates()
        updates.append(contentsOf: brewUpdates)

        // Check App Store (requires mas CLI)
        let masUpdates = try await checkAppStoreUpdates()
        updates.append(contentsOf: masUpdates)

        // Check direct downloads (Sparkle feeds)
        let directUpdates = try await checkDirectDownloadUpdates()
        updates.append(contentsOf: directUpdates)

        return updates
    }

    private func checkHomebrewUpdates() async throws -> [UpdateInfo] {
        let output = try await shell("brew outdated --cask --greedy --json")

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }

        var updates: [UpdateInfo] = []
        for item in json {
            guard let dict = item as? [String: Any],
                  let name = dict["name"] as? String,
                  let installed = dict["installed_versions"] as? [String],
                  let current = dict["current_versions"] as? [String] else {
                continue
            }

            updates.append(UpdateInfo(
                app: try await findApp(named: name),
                currentVersion: installed.first ?? "",
                latestVersion: current.first ?? "",
                downloadURL: URL(string: "https://brew.sh"),
                releaseNotes: nil,
                size: nil,
                source: .homebrew
            ))
        }

        return updates
    }

    private func checkAppStoreUpdates() async throws -> [UpdateInfo] {
        // Requires 'mas' CLI tool
        // mas list
        // mas outdated

        let output = try await shell("mas outdated")
        // Parse output...
        return []
    }

    private func checkDirectDownloadUpdates() async throws -> [UpdateInfo] {
        // Many apps use Sparkle framework
        // Check ~/Library/Preferences/<bundleid>.plist for SUFeedURL

        let prefsPath = "~/Library/Preferences"
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: prefsPath.expandTilde
        )

        var updates: [UpdateInfo] = []

        for file in contents {
            guard file.hasSuffix(".plist") else { continue }

            let plistPath = "\(prefsPath.expandTilde)/\(file)"
            guard let plist = NSDictionary(contentsOfFile: plistPath),
                  let feedURL = plist["SUFeedURL"] as? String else {
                continue
            }

            // Fetch appcast and parse
            if let update = try await checkSparkleFeed(feedURL) {
                updates.append(update)
            }
        }

        return updates
    }

    func update(_ update: UpdateInfo) async throws {
        switch update.source {
        case .homebrew:
            _ = try await shell("brew upgrade --cask \(update.app.name)")

        case .appStore:
            _ = try await shell("mas install \(update.app.bundleID)")

        case .directDownload:
            // Download and mount DMG, copy to Applications, unmount
            guard let url = update.downloadURL else { return }
            let dmgData = try await download(from: url)
            let dmgPath = "/tmp/\(update.app.name).dmg"
            try dmgData.write(to: URL(fileURLWithPath: dmgPath))

            // Mount and copy
            try await mountAndInstall(dmgPath, appName: update.app.name)

        case .sparkle:
            // Same as direct download
            break
        }
    }
}
```

---

# MODULE 3: DISK ANALYSIS (D-3xx)

## Product Requirements

### D-301: Visual Disk Map

**User Story:** As a user, I want a beautiful, interactive visualization of my disk usage that lets me quickly identify what's taking up space.

**Technical Specifications:**

```swift
struct DiskNode {
    let id: UUID
    let name: String
    let path: String
    let size: Int64
    let children: [DiskNode]  // Sorted by size
    let fileType: FileType?
    let depth: Int
    let parent: UUID?

    var isLeaf: Bool { children.isEmpty }
}

enum FileType {
    case image
    case video
    case audio
    case document
    case code
    case archive
    case system
    case other
}

struct SunburstSegment {
    let node: DiskNode
    let startAngle: Double
    let endAngle: Double
    let innerRadius: Double
    let outerRadius: Double
    let color: Color
}

struct DiskMapLayout {
    func layout(_ node: DiskNode, in rect: CGRect) -> [SunburstSegment] {
        var segments: [SunburstSegment] = []

        if node.isLeaf {
            // Leaf segment
            segments.append(SunburstSegment(
                node: node,
                startAngle: 0,
                endAngle: .pi * 2,
                innerRadius: rect.width / 2,
                outerRadius: rect.width / 2 + 20,
                color: color(for: node.fileType)
            ))
        } else {
            // Recursive layout for children
            let totalSize = node.children.reduce(0) { $0 + $1.size }
            var currentAngle: Double = 0

            for child in node.children {
                let fraction = Double(child.size) / Double(totalSize)
                let angle = fraction * .pi * 2

                segments.append(SunburstSegment(
                    node: child,
                    startAngle: currentAngle,
                    endAngle: currentAngle + angle,
                    innerRadius: rect.width / 2,
                    outerRadius: rect.width / 2 + 20,
                    color: color(for: child.fileType)
                ))

                currentAngle += angle
            }
        }

        return segments
    }

    private func color(for type: FileType?) -> Color {
        guard let type = type else { return .gray }
        switch type {
        case .image: return .blue
        case .video: return .purple
        case .audio: return .orange
        case .document: return .yellow
        case .code: return .green
        case .archive: return .red
        case .system: return .gray
        case .other: return .cyan
        }
    }
}

struct DiskMapView: View {
    let node: DiskNode
    @State private var zoomDepth: Int = 0
    @State private var selectedNode: UUID?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Render segments
                ForEach(segments(for: node, in: geometry.size)) { segment in
                    SunburstSegmentView(
                        segment: segment,
                        isSelected: segment.node.id == selectedNode
                    )
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3)) {
                            if segment.node.isLeaf {
                                selectedNode = segment.node.id
                            } else {
                                // Zoom into this node
                                zoomDepth += 1
                            }
                        }
                    }
                }

                // Center hole (doughnut chart style)
                Circle()
                    .fill(Color(NSColor.windowBackgroundColor))
                    .frame(width: size.width * 0.3, height: size.height * 0.3)

                // Selected info in center
                if let selected = selectedNode,
                   let info = node.find(id: selected) {
                    VStack(spacing: 4) {
                        Text(info.name)
                            .font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file))
                            .font(.subheadline)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
}
```

**Animation Strategy:**

```swift
struct ZoomTransition: ViewModifier {
    let fromNode: DiskNode
    let toNode: DiskNode

    func body(content: Content) -> some View {
        content
            .modifier(ZoomInEffect(from: frame(fromNode), to: frame(toNode)))
    }

    private func frame(_ node: DiskNode) -> CGRect {
        // Calculate the frame for the node's segment
        // Used for Hero-style zoom animation
        CGRect(x: 0, y: 0, width: 100, height: 100)
    }
}
```

**File References:**
- `cmd/analyze/main.go` - Scanner patterns
- `cmd/analyze/view.go` - Visualization patterns
- `cmd/analyze/scanner.go:26-270` - Concurrent scanning

---

### D-302: Hidden Space Scan

**Technical Specifications:**

```swift
struct HiddenSpaceData {
    let localSnapshots: [LocalSnapshot]
    let purgeableSpace: Int64
    let systemData: SystemData
    let totalHidden: Int64
}

struct LocalSnapshot {
    let date: Date
    let size: Int64
    let id: String
}

class HiddenSpaceScanner {
    private let helper: HelperService

    func scan() async throws -> HiddenSpaceData {
        // Requires privileged helper
        let snapshots = try await helper.scanLocalSnapshots()
        let purgeable = try await helper.calculatePurgeable()
        let systemData = try await helper.scanSystemData()

        return HiddenSpaceData(
            localSnapshots: snapshots,
            purgeableSpace: purgeable,
            systemData: systemData,
            totalHidden: snapshots.reduce(0) { $0 + $1.size } + purgeable
        )
    }
}

// Helper tool implementation
extension HelperService {
    func scanLocalSnapshots() async throws -> [LocalSnapshot] {
        let command = "tmutil listlocalsnapshots /"
        let output = try await runCommand(command)

        var snapshots: [LocalSnapshot] = []
        for line in output.components(separatedBy: .newlines) {
            // Parse: com.apple.TimeMachine.Snapshot@2025-01-20-123456
            if let range = line.range(of: "@")?.upperBound {
                let dateStr = String(line[range...])
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
                if let date = formatter.date(from: dateStr) {
                    snapshots.append(LocalSnapshot(
                        date: date,
                        size: 0,  // Calculated separately
                        id: String(line.split(separator: "@")[1])
                    ))
                }
            }
        }

        return snapshots
    }

    func deleteSnapshot(_ id: String) async throws {
        let command = "sudo tmutil deletelocalsnapshots \(id)"
        try await runCommand(command)
    }
}
```

---

### D-303: Cloud & Network Scan

**Technical Specifications:**

```swift
struct CloudService {
    enum ServiceType {
        case icloud
        case dropbox
        case googleDrive
        case oneDrive
    }

    let type: ServiceType
    let localPath: String
    let isAvailable: Bool
}

class CloudScanner {
    private let knownCloudPaths: [ServiceType: String] = [
        .icloud: "~/Library/Mobile Documents",
        .dropbox: "~/Dropbox",
        .googleDrive: "~/Google Drive",
        .oneDrive: "~/OneDrive"
    ]

    func detectCloudServices() -> [CloudService] {
        var services: [CloudService] = []

        for (type, path) in knownCloudPaths {
            let expanded = path.expandTilde
            let isAvailable = FileManager.default.fileExists(atPath: expanded)

            services.append(CloudService(
                type: type,
                localPath: expanded,
                isAvailable: isAvailable
            ))
        }

        return services
    }

    func scanCloudService(_ service: CloudService) async throws -> [ScanItem] {
        guard service.isAvailable else { return [] }

        var items: [ScanItem] = []
        let enumerator = FileManager.default.enumerator(
            atPath: service.localPath,
            includingPropertiesForKeys: [.fileSizeKey, .isUbiquitousItemKey]
        )

        for case let file as URL in enumerator {
            guard let resourceValues = try file.resourceValues(
                forKeys: [.fileSizeKey, .isUbiquitousItemKey]
            ) else { continue }

            let isDownloaded = resourceValues.ubiquitousItem?.isDownloaded == true
            let isDownloading = resourceValues.ubiquitousItem?.isDownloading == true

            // Show sync status
            items.append(ScanItem(
                path: file.path,
                size: resourceValues.fileSize ?? 0,
                type: .cloudFile,
                description: isDownloaded ? "Downloaded" :
                             isDownloading ? "Downloading..." : "Cloud Only"
            ))
        }

        return items
    }
}

class NetworkVolumeScanner {
    func scanNetworkVolumes() async throws -> [ScanItem] {
        // Mount points in /Volumes
        let volumesPath = "/Volumes"
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: volumesPath,
            includingPropertiesForKeys: [.volumeURLForKey]
        )

        var items: [ScanItem] = []

        for case let url as URL in contents {
            // Skip Macintosh HD
            if url.path == "/Volumes/Macintosh HD" { continue }

            // Check if network volume
            if let resourceValues = try? url.resourceValues(forKeys: [.volumeIsBrowsableKey, .volumeIsInternalKey]),
               resourceValues.volumeIsInternal == false {

                // Scan with timeout for slow network
                let volumeItems = try await scanWithTimeout(
                    path: url.path,
                    timeout: 30.seconds
                )
                items.append(contentsOf: volumeItems)
            }
        }

        return items
    }

    private func scanWithTimeout(path: String, timeout: TimeInterval) async throws -> [ScanItem] {
        try await withTimeout(seconds: timeout) {
            // Perform scan
            return []
        }
    }
}
```

---

### D-304: Collector Bin

**Technical Specifications:**

```swift
@Observable
class CollectorBin {
    var items: [CollectorItem] = []
    var totalSize: Int64 = 0

    func add(_ item: ScanItem) {
        if !items.contains(where: { $0.id == item.id }) {
            items.append(CollectorItem(from: item))
            recalculate()
        }
    }

    func remove(_ item: CollectorItem) {
        items.removeAll { $0.id == item.id }
        recalculate()
    }

    func empty() async throws -> EmptyResult {
        // Move to trash, not permanent delete
        for item in items {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path))
        }

        let total = totalSize
        items.removeAll()
        recalculate()

        return EmptyResult(
            itemCount: items.count,
            spaceReclaimed: total
        )
    }

    private func recalculate() {
        totalSize = items.reduce(0) { $0 + $1.size }
    }
}

struct CollectorItem: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
    let type: FileType
    let addedAt: Date
}

struct CollectorBinView: View {
    @State private var collector = CollectorBin()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🗑️ Collector")
                .font(.headline)

            Text("\(collector.items.count) items • \(ByteCountFormatter.string(fromByteCount: collector.totalSize, countStyle: .file))")
                .foregroundColor(.secondary)

            if collector.items.isEmpty {
                Text("Drag items here to stage for deletion")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List {
                    ForEach(collector.items) { item in
                        CollectorItemRow(item: item)
                            .contextMenu {
                                Button("Remove") { collector.remove(item) }
                            }
                    }
                }

                Button("Empty Collector") {
                    Task { try await collector.empty() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
```

---

# MODULE 4: LIVE MONITORING (M-4xx)

## Product Requirements

### M-401: Menu Bar Widgets

**Technical Specifications:**

```swift
protocol MenuBarWidget {
    var icon: String { get }
    var title: String { get }
    var isPro: Bool { get }
    func refresh() async -> WidgetData
}

struct WidgetData {
    let title: String
    let value: String
    let graph: [CGPoint]?  // Normalized 0-1
    let color: Color
}

// CPU Widget
struct CPUWidget: MenuBarWidget {
    let icon = "cpu"
    let title = "CPU"
    let isPro = false  // Basic

    func refresh() async -> WidgetData {
        let usage = await getCPUUsage()
        let graph = await history(for: .cpu, count: 60)

        return WidgetData(
            title: "\(Int(usage * 100))%",
            value: "\(Int(usage * 100))%",
            graph: graph,
            color: usage > 0.8 ? .red : usage > 0.5 ? .yellow : .green
        )
    }

    private func getCPUUsage() async -> Double {
        // Use sysctl or host_statistics
        var size = MemoryLayout<host_cpu_load_info>.stride
        var info = host_cpu_load_info()
        var numCpuU = mach_msg_type_number_t(MemoryLayout<mach_msg_type_number_t>.size)
        var numCpu: Int = 0

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size, &numCpuU)
            }
        }

        if result == KERN_SUCCESS {
            numCpu = Int(numCpuU)

            var totalTicks: UInt32 = 0
            var idleTicks: UInt32 = 0

            for i in 0..<Int32(numCpu) {
                totalTicks += info.cpu_ticks[i].cpu_ticks.0 +
                             info.cpu_ticks[i].cpu_ticks.1 +
                             info.cpu_ticks[i].cpu_ticks.2 +
                             info.cpu_ticks[i].cpu_ticks.3
                idleTicks += info.cpu_ticks[i].cpu_ticks.2
            }

            return 1.0 - Double(idleTicks) / Double(totalTicks)
        }

        return 0
    }
}

// GPU Widget (Pro)
struct GPUWidget: MenuBarWidget {
    let icon = "gpu"
    let title = "GPU"
    let isPro = true

    func refresh() async -> WidgetData {
        // Requires IOKit
        let usage = await getGPUUsage()
        return WidgetData(
            title: "\(Int(usage * 100))%",
            value: "\(Int(usage * 100))%",
            graph: nil,
            color: usage > 0.8 ? .red : .green
        )
    }
}

// Memory Widget
struct MemoryWidget: MenuBarWidget {
    let icon = "memory"
    let title = "Memory"
    let isPro = false

    func refresh() async -> WidgetData {
        let (used, total) = await getMemoryUsage()
        let pressure = await getMemoryPressure()

        return WidgetData(
            title: "\(ByteCountFormatter.string(fromByteCount: used, countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .memory))",
            value: "\(Int(Double(used) / Double(total) * 100))%",
            graph: await history(for: .memory, count: 60),
            color: pressure.color
        )
    }
}

// Menu Bar Manager
@Observable
class MenuBarManager {
    private let statusItem = NSStatusItem()
    private var widgets: [MenuBarWidget] = []

    func setup() {
        statusItem.button?.title = "📊"
        statusItem.button?.action = #selector(showMenu)

        // Add default widgets (Basic)
        addWidget(CPUWidget())
        addWidget(MemoryWidget())
        addWidget(DiskWidget())
        addWidget(NetworkWidget())
    }

    @objc func showMenu() {
        let menu = NSMenu()

        // Add widget views
        for widget in widgets {
            let menuItem = NSMenuItem()
            menuItem.view = NSHostingController(rootView: WidgetMenuItem(widget: widget)).view
            menu.addItem(menuItem)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Tonic", action: #selector(openApp), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Quit Tonic", action: #selector(terminateApp), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }
}
```

---

### M-402: Detailed Dropdown Views

**Technical Specifications:**

```swift
struct DetailedDropdownView: View {
    let widget: MenuBarWidget
    @State private var timeRange: TimeRange = .hour

    enum TimeRange {
        case minute    // 60 data points
        case hour     // 60 data points, one per minute
        case day      // 24 data points, one per hour
        case week     // 7 data points, one per day
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(widget.title)
                    .font(.headline)
                Spacer()
                Picker("", selection: $timeRange) {
                    Text("1H").tag(TimeRange.hour)
                    Text("1D").tag(TimeRange.day)
                    Text("1W").tag(TimeRange.week)
                }
                .pickerStyle(.segmented)
            }

            // Graph
            GraphView(data: historyData(for: timeRange))
                .frame(height: 80)

            // Process list
            if widget.showProcessList {
                ProcessListView(type: widget.type)
            }

            // Additional info
            if let details = widget.additionalDetails {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(details) { detail in
                        HStack {
                            Text(detail.key)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(detail.value)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 280)
    }
}

struct ProcessListView: View {
    let type: WidgetType
    @State private var processes: [ProcessInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Top Processes")
                .font(.subheadline)
                .foregroundColor(.secondary)

            ForEach(processes.prefix(5)) { process in
                HStack {
                    Text(process.name)
                        .frame(maxWidth: 120, alignment: .leading)
                    Spacer()
                    Text(process.value)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
```

---

### M-403: System Dashboard

**Technical Specifications:**

```swift
struct SystemDashboardView: View {
    @State private var healthScore: HealthScore = .good
    @State private var metrics: SystemMetrics?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Health Score
                HealthScoreCard(score: healthScore)

                // Metrics Grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ]) {
                    MetricCard(
                        title: "CPU",
                        value: metrics?.cpuUsage ?? 0,
                        unit: "%",
                        icon: "cpu.fill"
                    )
                    MetricCard(
                        title: "Memory",
                        value: metrics?.memoryUsage ?? 0,
                        unit: "%",
                        icon: "memorychip.fill"
                    )
                    MetricCard(
                        title: "Disk",
                        value: metrics?.diskUsage ?? 0,
                        unit: "%",
                        icon: "internaldrive.fill"
                    )
                    MetricCard(
                        title: "Network",
                        value: metrics?.networkUsage ?? 0,
                        unit: "Mbps",
                        icon: "network.fill"
                    )
                }
            }
            .padding()
        }
    }
}

struct HealthScoreCard: View {
    let score: HealthScore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Health Score")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(score.rawValue)")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(score.color)
            }

            // Score ring
            ZStack {
                Circle()
                    .stroke(score.color.opacity(0.2), lineWidth: 12)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: CGFloat(score.rawValue) / 100)
                    .stroke(score.color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(), value: score.rawValue)
            }

            Text(score.description)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
}

enum HealthScore: Int {
    case good = 80
    case warning = 50
    case critical = 20

    var color: Color {
        switch self {
        case .good: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var description: String {
        switch self {
        case .good: return "Your Mac is running optimally"
        case .warning: return "Some issues detected"
        case .critical: return "Immediate attention required"
        }
    }
}
```

---

### M-404: Smart Notifications

**Technical Specifications:**

```swift
enum NotificationType {
    case cpuOverheat
    case memoryPressureCritical
    case diskSpaceLow
    case batteryLow
    case scanComplete
    case updateAvailable
}

class NotificationService {
    private let center = UNUserNotificationCenter.current()

    func setup() async throws {
        let options: UNAuthorizationOptions = [.alert, .sound, .badge]
        try await center.requestAuthorization(options: options)
    }

    func schedule(_ type: NotificationType, preferences: NotificationPreferences) async throws {
        let content = UNMutableNotificationContent()

        switch type {
        case .cpuOverheat:
            content.title = "CPU Temperature Critical"
            content.body = "CPU temperature exceeds \(preferences.cpuThreshold)°C"
            content.sound = .default

        case .memoryPressureCritical:
            content.title = "Memory Pressure Critical"
            content.body = "Your Mac is running low on memory"
            content.sound = .default

        case .diskSpaceLow:
            content.title = "Disk Space Low"
            content.body = "Only \(preferences.diskThreshold)GB remaining"
            content.sound = .default

        case .batteryLow:
            content.title = "Battery Low"
            content.body = "\(preferences.batteryThreshold)% remaining"
            content.sound = .default

        case .scanComplete:
            content.title = "Smart Scan Complete"
            content.body = "Click to view results"
            content.sound = .default
            content.userInfo = ["action": "showScanResults"]

        case .updateAvailable:
            content.title = "Updates Available"
            content.body = "Click to view and install"
            content.sound = .default
            content.userInfo = ["action": "showUpdates"]
        }

        // Add action buttons
        if type == .scanComplete || type == .updateAvailable {
            let action = UNNotificationAction(identifier: "open", title: "Open")
            let category = UNNotificationCategory(
                identifier: type.categoryIdentifier,
                actions: [action],
                intentIdentifiers: []
            )
            center.setNotificationCategories([category])
            content.categoryIdentifier = type.categoryIdentifier
        }

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: 1,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: type.identifier,
            content: content,
            trigger: trigger
        )

        try await center.add(request)
    }
}

struct NotificationPreferences {
    var cpuThreshold: Double = 90
    var memoryThreshold: Double = 90
    var diskThreshold: Int = 10  // GB
    var batteryThreshold: Int = 10  // %
    var quietHoursEnabled: Bool = false
    var quietHoursStart: Date = Date()
    var quietHoursEnd: Date = Date()
}
```

---

# MODULE 5: DEVELOPER TOOLS (T-5xx)

## Product Requirements

### T-501: Project Artifact Purge

**Technical Specifications:**

```swift
struct ProjectType {
    let id: String
    let name: String
    let artifactPatterns: [String]
    let icon: String

    // Default protection period (days)
    let protectionPeriod: Int
}

extension ProjectType {
    static let all: [ProjectType] = [
        ProjectType(
            id: "nodejs",
            name: "Node.js",
            artifactPatterns: [
                "node_modules",
                ".npm",
                ".yarn/cache",
                ".pnpm-store"
            ],
            icon: "nodejs",
            protectionPeriod: 7
        ),
        ProjectType(
            id: "python",
            name: "Python",
            artifactPatterns: [
                "__pycache__",
                "*.pyc",
                "*.pyo",
                "venv",
                ".venv",
                "env",
                ".pytest_cache"
            ],
            icon: "python",
            protectionPeriod: 7
        ),
        ProjectType(
            id: "rust",
            name: "Rust",
            artifactPatterns: [
                "target",
                "Cargo.lock"
            ],
            icon: "rust",
            protectionPeriod: 7
        ),
        ProjectType(
            id: "go",
            name: "Go",
            artifactPatterns: [
                "vendor",
                "*.exe",
                "*.test"
            ],
            icon: "go",
            protectionPeriod: 7
        ),
        ProjectType(
            id: "java",
            name: "Java",
            artifactPatterns: [
                ".gradle",
                "gradle",
                "target",
                "*.class",
                ".m2"
            ],
            icon: "java",
            protectionPeriod: 7
        ),
        ProjectType(
            id: "flutter",
            name: "Flutter",
            artifactPatterns: [
                "build",
                ".dart_tool"
            ],
            icon: "flutter",
            protectionPeriod: 7
        ),
        ProjectType(
            id: "xcode",
            name: "Xcode",
            artifactPatterns: [
                "DerivedData",
                "build"
            ],
            icon: "xcode",
            protectionPeriod: 14  // Longer for Xcode
        ),
    ]
}

class ProjectScanner {
    func scan(_ directories: [URL], types: [ProjectType]) async throws -> [ProjectArtifact] {
        var artifacts: [ProjectArtifact] = []

        for directory in directories {
            // Detect project type
            let type = detectProjectType(in: directory)
            guard let projectType = type else { continue }

            // Skip if recently modified
            if let modDate = try? FileManager.default.attributesOfItem(
                atPath: directory.path
            )[.modificationDate] as? Date {
                let daysSinceModified = Date().timeIntervalSince(modDate) / 86400
                if daysSinceModified < Double(projectType.protectionPeriod) {
                    continue  // Skip recently modified projects
                }
            }

            // Find artifacts
            let artifactPaths = try await findArtifacts(
                in: directory,
                patterns: projectType.artifactPatterns
            )

            let totalSize = artifactPaths.reduce(0) {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64) ?? 0
            }

            artifacts.append(ProjectArtifact(
                projectPath: directory.path,
                projectName: directory.lastPathComponent,
                type: projectType,
                artifacts: artifactPaths,
                totalSize: totalSize,
                lastModified: modDate ?? Date()
            ))
        }

        return artifacts.sorted { $0.totalSize > $1.totalSize }
    }

    private func detectProjectType(in directory: URL) -> ProjectType? {
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: directory.path,
            includingPropertiesForKeys: nil
        )

        for case let file as URL in (contents ?? []) {
            let fileName = file.lastPathComponent

            for type in ProjectType.all {
                if type.artifactPatterns.contains(fileName) ||
                   fileName == "package.json" && type.id == "nodejs" ||
                   fileName == "requirements.txt" && type.id == "python" ||
                   fileName == "Cargo.toml" && type.id == "rust" ||
                   fileName == "go.mod" && type.id == "go" {
                    return type
                }
            }
        }

        return nil
    }
}
```

---

### T-502: Docker/VM Cleanup

**Technical Specifications:**

```swift
struct DockerArtifact {
    enum ArtifactType {
        case image
        case container
        case volume
        case buildCache
    }

    let type: ArtifactType
    let id: String
    let size: Int64
    let created: Date?
    let state: String?
}

class DockerScanner {
    func scan() async throws -> [DockerArtifact] {
        var artifacts: [DockerArtifact] = []

        // Check if Docker is installed
        guard try await shell("which docker") != "" else {
            return []
        }

        // Scan images
        let images = try await scanImages()
        artifacts.append(contentsOf: images)

        // Scan containers
        let containers = try await scanContainers()
        artifacts.append(contentsOf: containers)

        // Scan volumes
        let volumes = try await scanVolumes()
        artifacts.append(contentsOf: volumes)

        // Scan build cache
        let cache = try await scanBuildCache()
        artifacts.append(contentsOf: cache)

        return artifacts
    }

    private func scanImages() async throws -> [DockerArtifact] {
        let output = try await shell("docker images --format '{{.ID}}|{{.Size}}|{{.CreatedAt}}'")

        var artifacts: [DockerArtifact] = []
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count >= 3 else { continue }

            let size = parseDockerSize(parts[1]) ?? 0
            artifacts.append(DockerArtifact(
                type: .image,
                id: parts[0],
                size: size,
                created: ISO8601DateFormatter().date(from: parts[2]),
                state: nil
            ))
        }

        return artifacts
    }

    private func scanContainers() async throws -> [DockerArtifact] {
        let output = try await shell("docker ps -a --format '{{.ID}}|{{.Size}}|{{.State}}'")

        var artifacts: [DockerArtifact] = []
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count >= 3 else { continue }

            artifacts.append(DockerArtifact(
                type: .container,
                id: parts[0],
                size: parseDockerSize(parts[1]) ?? 0,
                created: nil,
                state: parts[2]
            ))
        }

        return artifacts.filter { $0.state?.contains("Exited") == true }
    }

    private func scanVolumes() async throws -> [DockerArtifact] {
        let output = try await shell("docker volume ls --format '{{.Name}}|{{.Mountpoint}}'")

        var artifacts: [DockerArtifact] = []
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: "|").map(String.init)
            guard parts.count >= 2 else { continue }

            let mountPoint = parts.count > 1 ? parts[1] : ""
            let size = (try? FileManager.default.attributesOfItem(
                atPath: mountPoint
            )[.size] as? Int64) ?? 0

            artifacts.append(DockerArtifact(
                type: .volume,
                id: parts[0],
                size: size,
                created: nil,
                state: nil
            ))
        }

        return artifacts.filter { $0.size > 0 }  // Only show volumes with content
    }

    func cleanup(_ artifacts: [DockerArtifact]) async throws {
        for artifact in artifacts {
            switch artifact.type {
            case .image:
                _ = try await shell("docker rmi \(artifact.id)")
            case .container:
                _ = try await shell("docker rm \(artifact.id)")
            case .volume:
                _ = try await shell("docker volume rm \(artifact.id)")
            case .buildCache:
                _ = try await shell("docker builder prune -f")
            }
        }
    }
}

struct VMDiskImage {
    let path: String
    let type: VMType
    let size: Int64

    enum VMType {
        case vmware     // .vmdk
        case virtualbox // .vdi, .vmdk
        case parallels  // .pvm
        case qemu       // .qcow2
    }
}

class VMScanner {
    func scan() async throws -> [VMDiskImage] {
        var images: [VMDiskImage] = []

        // Search common VM directories
        let searchPaths = [
            "~/VirtualBox VMs",
            "~/Documents/Virtual Machines",
            "~/Documents/Parallels",
            "~/Documents/VMware",
        ]

        for basePath in searchPaths {
            let expanded = basePath.expandTilde
            guard FileManager.default.fileExists(atPath: expanded) else { continue }

            let enumerator = FileManager.default.enumerator(
                atPath: expanded,
                includingPropertiesForKeys: [.fileSizeKey]
            )

            for case let file as URL in enumerator {
                let ext = file.pathExtension.lowercased()
                guard ["vmdk", "vdi", "pvm", "qcow2"].contains(ext) else { continue }

                let type: VMType.VMType
                switch ext {
                case "vmdk": type = .vmware
                case "vdi": type = .virtualbox
                case "pvm": type = .parallels
                case "qcow2": type = .qemu
                default: continue
                }

                images.append(VMDiskImage(
                    path: file.path,
                    type: type,
                    size: (try? file.resourceValues(forKeys: [.fileSizeKey])?.fileSize) ?? 0
                ))
            }
        }

        return images.sorted { $0.size > $1.size }
    }
}
```

---

# CROSS-CUTTING CONCERNS

## Security

```swift
class SecurityService {
    // Validate paths before deletion
    func validate(_ paths: [String]) -> [String] {
        return paths.filter { path in
            // Check against protected patterns
            for pattern in Security.protectedPatterns {
                if path.range(of: pattern, options: .regularExpression) != nil {
                    return false
                }
            }

            // Check protected apps
            if let bundleID = getBundleID(for: path) {
                if Security.protectedApps.contains(bundleID) {
                    return false
                }
            }

            return true
        }
    }

    // Sanitize filenames for display
    func sanitize(_ path: String) -> String {
        // Replace home directory with ~
        var result = path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )

        // Hide long middle portions
        if result.count > 50 {
            let parts = result.components(separatedBy: "/")
            if parts.count > 3 {
                let first = parts.first ?? ""
                let last = parts.last ?? ""
                result = "\(first)/.../\(last)"
            }
        }

        return result
    }
}

extension Security {
    static let protectedPatterns = [
        "^/System",
        "^/Library/Apple",
        "^/Library/Application Support/Apple",
        "^/usr",
        "^/bin",
        "^/sbin",
    ]

    static let protectedApps = [
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.dock",
        "com.apple.Spotlight",
    ]
}
```

## Performance Optimization

```swift
class PerformanceOptimizer {
    // Virtualized list rendering for large datasets
    func virtualizedList<Item>(
        _ items: [Item],
        content: @escaping (Item) -> some View
    ) -> some View {
        List {
            ForEach(items) { item in
                content(item)
                    .onAppear {
                        // Preload next items if needed
                    }
            }
        }
    }

    // Progressive loading
    func progressiveLoad<T>(
        source: AsyncStream<T>,
        update: @escaping (T) -> Void
    ) async {
        for await item in source {
            update(item)
        }
    }

    // Background scanning with progress
    func scanWithProgress(
        path: String,
        progress: @escaping (ScanProgress) -> Void
    ) async throws -> ScanResult {
        var result = ScanResult()

        for await chunk in scanChunked(path: path, chunkSize: 1000) {
            result.items.append(contentsOf: chunk)
            progress(.init(
                itemsScanned: result.items.count,
                currentPath: chunk.last?.path ?? ""
            ))
        }

        return result
    }
}
```

## Accessibility

```swift
struct AccessibleScanView: View {
    @State private var scanResult: ScanResult?

    var body: some View {
        VStack {
            if let result = scanResult {
                List(result.items) { item in
                    HStack {
                        Image(systemName: icon(for: item.type))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading) {
                            Text(item.name)
                                .accessibilityLabel("File: \(item.name)")

                            Text(ByteCountFormatter.string(
                                fromByteCount: item.size,
                                countStyle: .file
                            ))
                            .accessibilityLabel("Size: \(formatSize(item.size))")
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { item.selected },
                            set: { item.selected = $0 }
                        ))
                        .accessibilityLabel("Selected for deletion")
                        .accessibilityHint(item.selected ? "Tap to deselect" : "Tap to select")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityLabel("Scan Results")
        .accessibilityHint("List of files found during scan")
    }
}
```

## Localization

```swift
// Use Localizable.strings
/* Smart Scan */
"smart_scan.title" = "Smart Scan";
"smart_scan.description" = "Scan your Mac for issues";
"smart_scan.running" = "Scanning...";
"smart_scan.complete" = "Scan Complete";

/* Health Score */
"health_score.good" = "Good";
"health_score.warning" = "Needs Attention";
"health_score.critical" = "Critical";

// Usage in SwiftUI
Text("smart_scan.title")
```

---

# TESTING STRATEGY

## Unit Tests

```swift
class SmartScanServiceTests: XCTestCase {
    var sut: SmartScanService!

    override func setUp() {
        super.setUp()
        sut = SmartScanService()
    }

    func testHealthScoreCalculation() {
        let junk = JunkCategory(
            caches: [],
            logs: [],
            downloads: [],
            trash: [],
            totalSize: 5_000_000_000  // 5GB
        )

        let score = sut.calculateHealthScore(junk: junk)

        XCTAssertLessThan(score, 50, "5GB of junk should result in poor score")
    }

    func testScanSpeed() throws {
        let expectation = XCTestExpectation(description: "Scan completes in 30 seconds")

        Task {
            let result = try await sut.scan()
            XCTAssertTrue(result.healthScore >= 0)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 30.0)
    }
}
```

## Integration Tests

```swift
class IntegrationTests: XCTestCase {
    func testFullScanAndClean() async throws {
        let scanService = SmartScanService()
        let cleanupService = CleanupService()

        // Scan
        let result = try await scanService.scan()
        XCTAssertFalse(result.items.isEmpty)

        // Clean
        let cleanupResult = try await cleanupService.clean(
            result.items.filter { $0.selected }
        )

        XCTAssertGreaterThan(cleanupResult.spaceReclaimed, 0)
    }
}
```

---

# QUICK COMMANDS

```bash
# Foundation
mkdir -p Tonic
cd Tonic
swift package init --type executable

# Build and run (development)
swift run

# Test
swift test

# Verification
swift --version  # Should be 5.9+ for macOS 14 target
lipo -info Tonic.app/Contents/MacOS/Tonic
sudo launchctl list | grep tonic
codesign -dv --verbose=4 Tonic.app
```

---

# REFERENCES

## Codebase (Mole)
- `mole:1-789` - Main CLI entry point
- `cmd/analyze/main.go` - Disk scanner
- `cmd/status/main.go` - System dashboard
- `bin/uninstall.sh:1-587` - Uninstaller logic
- `lib/clean/` - All cleanup modules
- `lib/optimize/tasks.sh:104-779` - Optimization functions
- `lib/core/app_protection.sh` - Protected apps whitelist

## External Documentation
- [Apple HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [SMJobBless Sample](https://developer.apple.com/library/archive/samplecode/EvenBetterAuthorizationSample/)
- [Sparkle Framework](https://sparkle-project.org/)
- [SwiftUI Animations](https://developer.apple.com/videos/play/wwdc2025/)

## Competitor Research
- CleanMyMac X - Feature benchmark
- DaisyDisk - Visualization gold standard
- AppCleaner - Uninstaller UX
- iStat Menus - Menu bar widgets
