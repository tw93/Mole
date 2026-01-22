# Technical Documentation

A comprehensive technical guide to Tonic's architecture, implementation details, and code examples.

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [Core Services Layer](#2-core-services-layer)
3. [Monitoring Layer](#3-monitoring-layer)
4. [Menu Bar Widgets](#4-menu-bar-widgets)
5. [User Interface](#5-user-interface)
6. [App Management](#6-app-management)
7. [Permissions and Security](#7-permissions-and-security)
8. [Data Models](#8-data-models)
9. [Build and Development](#9-build-and-development)

---

## 1. System Architecture

### 1.1 App Entry Point and Lifecycle

Tonic's application lifecycle is managed by `TonicApp.swift` and `AppDelegate`. The app uses SwiftUI's `@main` attribute with an `NSApplicationDelegateAdaptor` for deep macOS integration.

```swift
// Tonic/Tonic/TonicApp.swift
@main
struct TonicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Tonic") { appDelegate.showAbout() }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") { appDelegate.showPreferences() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Help") {
                Button("Tonic Documentation") {
                    if let url = URL(string: "https://github.com/tw93/Tonic") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}
```

The `AppDelegate` class handles system-level integration:

```swift
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupUserDefaults()
        applyThemePreference()
        startWidgetSystem()
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: NSNotification.Name("TonicThemeDidChange"),
            object: nil
        )
    }
    
    private func startWidgetSystem() {
        let hasCompletedOnboarding = UserDefaults.standard.bool(
            forKey: "tonic.widget.hasCompletedOnboarding"
        )
        if hasCompletedOnboarding {
            WidgetCoordinator.shared.start()
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // Keep app running for menu bar widgets
    }
}
```

**Key Lifecycle Points:**
- `NSApp.setActivationPolicy(.regular)` - Shows dock icon (change to `.accessory` for menu-bar-only mode)
- `applicationShouldTerminateAfterLastWindowClosed` returns `false` - App persists after window closes
- Widget system starts only after onboarding completion

### 1.2 Navigation Architecture

Tonic uses `NavigationSplitView` for a sidebar-based navigation pattern:

```swift
// Tonic/Tonic/Views/ContentView.swift
struct ContentView: View {
    @State private var selectedDestination: NavigationDestination = .dashboard
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showOnboarding = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedDestination: $selectedDestination)
        } detail: {
            switch selectedDestination {
            case .dashboard:
                DashboardView()
            case .systemCleanup:
                SmartScanView()
            case .appManager:
                AppInventoryView()
            case .diskAnalysis:
                DiskAnalysisView()
            case .liveMonitoring:
                SystemStatusDashboard()
            case .menuBarWidgets:
                WidgetsPanelView()
            case .developerTools:
                DeveloperToolsView()
            case .settings:
                PreferencesView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            checkPermissionsAndOnboarding()
        }
    }
}
```

The `NavigationDestination` enum defines all navigation targets:

```swift
// Tonic/Tonic/Models/NavigationModels.swift
enum NavigationDestination: String, CaseIterable {
    case dashboard = "Dashboard"
    case systemCleanup = "System Cleanup"
    case appManager = "App Manager"
    case diskAnalysis = "Disk Analysis"
    case liveMonitoring = "Live Monitoring"
    case menuBarWidgets = "Menu Bar Widgets"
    case developerTools = "Developer Tools"
    case settings = "Settings"
    
    var systemImage: String {
        switch self {
        case .dashboard: return "chart.line.uptrend.xyaxis"
        case .systemCleanup: return "sparkles"
        case .appManager: return "app.badge"
        case .diskAnalysis: return "externaldrive.fill"
        case .liveMonitoring: return "gauge"
        case .menuBarWidgets: return "square.grid.2x2"
        case .developerTools: return "hammer.fill"
        case .settings: return "gear"
        }
    }
}
```

### 1.3 State Management

Tonic employs multiple state management patterns:

#### Observable Classes (macOS 14+)

```swift
// Tonic/Tonic/Services/SmartScanEngine.swift
@Observable
final class SmartScanEngine: @unchecked Sendable {
    private var _scanData: ScanData = .init()
    var currentStage: ScanStage = .preparing
    var scanProgress: Double = 0.0
    var isScanning: Bool = false
    
    func runStage(_ stage: ScanStage) async -> Double {
        // Stage implementation
    }
    
    func finalizeScan() async -> SmartScanResult {
        // Calculate health score
        let diskScore = calculateDiskScore()
        let recommendationScore = calculateRecommendationScore()
        let healthScore = Int((Double(diskScore) * 0.6 + Double(recommendationScore) * 0.4))
        
        return SmartScanResult(
            healthScore: healthScore,
            scanData: _scanData,
            recommendations: generateRecommendations()
        )
    }
}
```

#### ViewModel with @StateObject

```swift
// Tonic/Tonic/Views/DashboardView.swift
@MainActor
class SmartScanManager: ObservableObject {
    @Published var isScanning = false
    @Published var scanProgress: Double = 0.0
    @Published var currentPhase: ScanPhase = .idle
    @Published var lastScanResult: ScanResult?
    @Published var healthScore: Int = 85
    @Published var activityHistory: [ActivityItem] = []
    @Published var recommendations: [Recommendation] = []
}
```

#### Singleton Pattern for Shared Services

```swift
// Tonic/Tonic/Models/WidgetConfiguration.swift
@MainActor
@Observable
public final class WidgetPreferences: Sendable {
    public static let shared = WidgetPreferences()
    
    public var widgetConfigs: [WidgetConfiguration] = []
    public var updateInterval: WidgetUpdateInterval = .balanced
    public var hasCompletedOnboarding: Bool = false
    
    private init() {
        loadFromUserDefaults()
    }
}
```

#### AppStorage for User Defaults

```swift
// Tonic/Tonic/Views/PreferencesView.swift
@AppStorage("launchAtLogin") private var launchAtLogin = false
@AppStorage("automaticallyChecksForUpdates") private var automaticallyChecksForUpdates = true
@AppStorage("themePreference") private var themePreference = "dark"
```

### 1.4 Design System

Tonic's design system is defined in three files:

#### Design Tokens

```swift
// Tonic/Tonic/Design/DesignTokens.swift
enum DesignTokens {
    enum Colors {
        static let accent = Color(red: 0.30, green: 0.50, blue: 1.00)
        static let pro = Color(red: 1.00, green: 0.75, blue: 0.00)
        static let success = Color(red: 0.20, green: 0.80, blue: 0.40)
        static let error = Color(red: 1.00, green: 0.30, blue: 0.30)
        static let warning = Color(red: 1.00, green: 0.60, blue: 0.00)
        
        static let background = Color(nsColor: .windowBackgroundColor)
        static let surface = Color(red: 0.12, green: 0.12, blue: 0.13)
        static let surfaceElevated = Color(red: 0.16, green: 0.16, blue: 0.17)
        static let text = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        
        static let progressLow = Color(red: 0.20, green: 0.80, blue: 0.40)
        static let progressMedium = Color(red: 1.00, green: 0.60, blue: 0.00)
        static let progressHigh = Color(red: 1.00, green: 0.30, blue: 0.30)
    }
    
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }
    
    enum CornerRadius {
        static let small: CGFloat = 4
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
        static let round: CGFloat = 9999
    }
    
    enum AnimationDuration {
        static let fast: Double = 0.15
        static let normal: Double = 0.25
        static let slow: Double = 0.35
    }
    
    enum AnimationCurve {
        static let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)
        static let springBouncy = Animation.spring(response: 0.5, dampingFraction: 0.5)
        static let smooth = Animation.easeInOut(duration: 0.25)
    }
}
```

#### Design Components

```swift
// Tonic/Tonic/Design/DesignComponents.swift
struct Card<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content()
            .padding(DesignTokens.Spacing.md)
            .background(DesignTokens.Colors.surface)
            .cornerRadius(DesignTokens.CornerRadius.large)
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }
}

struct PrimaryButton: View {
    let title: String
    let icon: String?
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                if let icon = icon {
                    Image(systemName: icon)
                }
                Text(title)
                    .font(DesignTokens.Typography.headlineSmall)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(isHovered ? DesignTokens.Colors.accent : DesignTokens.Colors.accent.opacity(0.9))
            .foregroundColor(.white)
            .cornerRadius(DesignTokens.CornerRadius.medium)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}

enum StatusLevel {
    case healthy, warning, critical, unknown
    
    var color: Color {
        switch self {
        case .healthy: return DesignTokens.Colors.progressLow
        case .warning: return DesignTokens.Colors.progressMedium
        case .critical: return DesignTokens.Colors.progressHigh
        case .unknown: return DesignTokens.Colors.textSecondary
        }
    }
    
    var icon: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}
```

#### Design Animations

```swift
// Tonic/Tonic/Design/DesignAnimations.swift
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0),
                            Color.white.opacity(0.3),
                            Color.white.opacity(0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 2)
                    .offset(x: -geometry.size.width + (phase * geometry.size.width * 2))
                }
            )
            .mask(content)
            .onAppear {
                withAnimation(
                    Animation.linear(duration: 1.5).repeatForever(autoreverses: false)
                ) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
    
    func fadeIn(delay: Double = 0) -> some View {
        self.opacity(0)
            .animation(.easeIn(duration: 0.3).delay(delay), value: true)
            .opacity(1)
    }
    
    func scaleIn(delay: Double = 0) -> some View {
        self.scaleEffect(0.9)
            .animation(
                Animation.spring(response: 0.3, dampingFraction: 0.7).delay(delay),
                value: true
            )
            .scaleEffect(1)
    }
    
    func skeleton() -> some View {
        self.shimmer()
            .redacted(reason: .placeholder)
    }
}
```

---

## 2. Core Services Layer

### 2.1 SmartScanEngine

The SmartScanEngine performs multi-stage system analysis to generate a health score and actionable recommendations.

```swift
// Tonic/Tonic/Services/SmartScanEngine.swift
@Observable
final class SmartScanEngine: @unchecked Sendable {
    private var _scanData: ScanData = .init()
    private var whitelistStore = WhitelistStore.shared
    
    var currentStage: ScanStage = .preparing
    var scanProgress: Double = 0.0
    var isScanning: Bool = false
    
    enum ScanStage: String, CaseIterable, Identifiable {
        case preparing = "Preparing"
        case scanningDisk = "Scanning Disk"
        case checkingApps = "Checking Apps"
        case analyzingSystem = "Analyzing System"
        case complete = "Complete"
        
        var id: String { rawValue }
    }
    
    func runScan() async -> SmartScanResult {
        isScanning = true
        defer { isScanning = false }
        
        // Stage 1: Preparing
        currentStage = .preparing
        scanProgress = 0.0
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // Stage 2: Scanning Disk
        currentStage = .scanningDisk
        scanProgress = 0.2
        await scanDiskUsage()
        
        // Stage 3: Checking Apps
        currentStage = .checkingApps
        scanProgress = 0.5
        await checkApplications()
        
        // Stage 4: Analyzing System
        currentStage = .analyzingSystem
        scanProgress = 0.8
        await analyzeSystem()
        
        // Stage 5: Complete
        currentStage = .complete
        scanProgress = 1.0
        
        return finalizeScan()
    }
    
    private func scanDiskUsage() async {
        let userCaches = getUserCacheSize()
        let systemCaches = getSystemCacheSize()
        let logsSize = getLogsSize()
        let tempFiles = getTempFilesSize()
        
        _scanData.junkFiles = JunkCategory(
            cacheFiles: userCaches + systemCaches,
            logFiles: logsSize,
            tempFiles: tempFiles,
            trashItems: getTrashSize(),
            browserCache: getBrowserCacheSize(),
            languagePacks: getLanguagePackSize()
        )
    }
    
    private func checkApplications() async {
        let unusedApps = findUnusedApps()
        let largeApps = findLargeApps()
        let duplicates = findDuplicateApps()
        let orphaned = findOrphanedFiles()
        
        _scanData.appIssues = AppIssueCategory(
            unusedApps: unusedApps,
            largeApps: largeApps,
            duplicateApps: duplicates,
            orphanedFiles: orphaned
        )
    }
    
    private func analyzeSystem() async {
        let hiddenSpace = await scanHiddenSpace()
        let performanceIssues = detectPerformanceIssues()
        
        _scanData.hiddenSpace = hiddenSpace
        _scanData.performanceIssues = performanceIssues
    }
    
    private func finalizeScan() async -> SmartScanResult {
        let diskUsage = calculateDiskUsageScore()
        let cacheScore = calculateCacheScore()
        let appScore = calculateAppScore()
        let performanceScore = calculatePerformanceScore()
        
        let healthScore = Int(
            (Double(diskUsage) * 0.25) +
            (Double(cacheScore) * 0.25) +
            (Double(appScore) * 0.25) +
            (Double(performanceScore) * 0.25)
        )
        
        let recommendations = generateRecommendations()
        
        return SmartScanResult(
            healthScore: max(0, min(100, healthScore)),
            scanData: _scanData,
            recommendations: recommendations
        )
    }
    
    private func generateRecommendations() -> [ScanRecommendation] {
        var recommendations: [ScanRecommendation] = []
        
        if _scanData.junkFiles.cacheFiles > 1_000_000_000 {
            recommendations.append(ScanRecommendation(
                title: "Clear Cache Files",
                description: "Over \(ByteCountFormatter.string(fromBytes: _scanData.junkFiles.cacheFiles, countStyle: .file)) of cache files can be safely removed",
                category: .cache,
                potentialSpace: _scanData.junkFiles.cacheFiles,
                priority: .high
            ))
        }
        
        if _scanData.junkFiles.logFiles > 500_000_000 {
            recommendations.append(ScanRecommendation(
                title: "Remove Log Files",
                description: "Log files are taking up \(ByteCountFormatter.string(fromBytes: _scanData.junkFiles.logFiles, countStyle: .file))",
                category: .logs,
                potentialSpace: _scanData.junkFiles.logFiles,
                priority: .medium
            ))
        }
        
        return recommendations
    }
}
```

### 2.2 DeepCleanEngine

The DeepCleanEngine handles cleanup across 10 categories with progress tracking:

```swift
// Tonic/Tonic/Services/DeepCleanEngine.swift
@Observable
public final class DeepCleanEngine: @unchecked Sendable {
    public var isScanning = false
    public var isCleaning = false
    public var scanProgress: Double = 0
    public var cleanProgress: Double = 0
    
    public enum DeepCleanCategory: String, CaseIterable, Identifiable {
        case systemCache = "System Cache"
        case userCache = "User Cache"
        case logFiles = "Log Files"
        case tempFiles = "Temporary Files"
        case browserCache = "Browser Cache"
        case downloads = "Downloads Folder"
        case trash = "Trash"
        case development = "Development Artifacts"
        case docker = "Docker"
        case xcode = "Xcode"
        
        public var id: String { rawValue }
        
        public var description: String {
            switch self {
            case .systemCache: return "macOS system caches"
            case .userCache: return "Application user caches"
            case .logFiles: return "System and app log files"
            case .tempFiles: return "Temporary files"
            case .browserCache: return "Browser data and cache"
            case .downloads: return "Downloaded files older than 30 days"
            case .trash: return "Items in Trash"
            case .development: return "Node modules, build artifacts, etc."
            case .docker: return "Docker containers and images"
            case .xcode: return "DerivedData, Archives, DeviceSupport"
            }
        }
        
        public var icon: String {
            switch self {
            case .systemCache: return "externaldrive.fill"
            case .userCache: return "internaldrive.fill"
            case .logFiles: return "doc.text.fill"
            case .tempFiles: return "tray"
            case .browserCache: return "globe"
            case .downloads: return "arrow.down.circle.fill"
            case .trash: return "trash.fill"
            case .development: return "hammer.fill"
            case .docker: return "shippingbox.fill"
            case .xcode: return "xcode"
            }
        }
    }
    
    public func scanAllCategories() async -> [DeepCleanResult] {
        isScanning = true
        defer { isScanning = false }
        
        var results: [DeepCleanResult] = []
        let totalCategories = DeepCleanCategory.allCases.count
        
        for (index, category) in DeepCleanCategory.allCases.enumerated() {
            scanProgress = Double(index) / Double(totalCategories)
            let result = await scanCategory(category)
            results.append(result)
        }
        
        scanProgress = 1.0
        return results
    }
    
    public func cleanCategories(_ categories: [DeepCleanCategory]) async -> Int64 {
        isCleaning = true
        defer { isCleaning = false }
        
        var totalFreed: Int64 = 0
        let total = categories.count
        
        for (index, category) in categories.enumerated() {
            cleanProgress = Double(index) / Double(total)
            let freed = await cleanCategory(category)
            totalFreed += freed
        }
        
        cleanProgress = 1.0
        return totalFreed
    }
    
    private func scanCategory(_ category: DeepCleanCategory) async -> DeepCleanResult {
        let items: [URL]
        let totalSize: Int64
        
        switch category {
        case .systemCache:
            let paths = ["/Library/Caches", "/System/Library/Caches"]
            (items, totalSize) = await scanPaths(paths)
            
        case .userCache:
            let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            (items, totalSize) = await scanPath(path)
            
        case .logFiles:
            let paths = [
                "~/Library/Logs",
                "/Library/Logs",
                "~/Library/Logs/DiagnosticReports"
            ]
            (items, totalSize) = await scanPaths(paths.map { NSString(string: $0).expandingTildeInPath })
            
        case .tempFiles:
            (items, totalSize) = await scanTempFiles()
            
        case .browserCache:
            (items, totalSize) = await scanBrowserCache()
            
        case .downloads:
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            (items, totalSize) = await scanOldDownloads(at: downloads)
            
        case .trash:
            let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0]
            (items, totalSize) = await scanPath(trash)
            
        case .development:
            (items, totalSize) = await scanDevelopmentArtifacts()
            
        case .docker:
            (items, totalSize) = await scanDocker()
            
        case .xcode:
            (items, totalSize) = await scanXcode()
        }
        
        return DeepCleanResult(
            category: category,
            items: items,
            totalSize: totalSize
        )
    }
    
    private func scanDevelopmentArtifacts() async -> ([URL], Int64) {
        let patterns = [
            "node_modules",
            ".gradle",
            "target",
            "build",
            "dist",
            ".cargo",
            ".m2",
            "Pods",
            ".venv",
            "venv"
        ]
        
        let searchPaths = [
            "~/Projects",
            "~/Developer",
            "~/Documents",
            "~/Desktop"
        ]
        
        var allItems: [URL] = []
        var totalSize: Int64 = 0
        
        for basePath in searchPaths {
            let url = URL(fileURLWithPath: NSString(string: basePath).expandingTildeInPath)
            if let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let isDirectory = resourceValues?.isDirectory ?? false
                    let size = Int64(resourceValues?.fileSize ?? 0)
                    
                    if !isDirectory {
                        let fileName = fileURL.lastPathComponent
                        if patterns.contains(where: { fileName == $0 || fileName.hasPrefix($0) }) {
                            allItems.append(fileURL)
                            totalSize += size
                        }
                    }
                }
            }
        }
        
        return (allItems, totalSize)
    }
}
```

### 2.3 SystemOptimization

Performs system-level optimization operations:

```swift
// Tonic/Tonic/Services/SystemOptimization.swift
@Observable
public final class SystemOptimization: @unchecked Sendable {
    public var lastResult: OptimizationResult?
    public var isOptimizing = false
    
    public enum OptimizationAction: String, CaseIterable, Identifiable, Sendable {
        case flushDNS = "Flush DNS Cache"
        case clearRAM = "Clear Inactive Memory"
        case rebuildLaunchServices = "Rebuild Launch Services"
        case cleanQuickLook = "Clean QuickLook Cache"
        case cleanFonts = "Clean Font Cache"
        
        public var id: String { rawValue }
        
        public var description: String {
            switch self {
            case .flushDNS: return "Clear DNS resolver cache"
            case .clearRAM: return "Purge inactive memory pages"
            case .rebuildLaunchServices: return "Refresh application opening database"
            case .cleanQuickLook: return "Clear QuickLook thumbnail cache"
            case .cleanFonts: return "Clear font registration cache"
            }
        }
        
        public var icon: String {
            switch self {
            case .flushDNS: return "network"
            case .clearRAM: return "memorychip"
            case .rebuildLaunchServices: return "app.badge"
            case .cleanQuickLook: return "photo.on.rectangle"
            case .cleanFonts: return "textformat.size"
            }
        }
    }
    
    public func performAction(_ action: OptimizationAction) async throws -> OptimizationResult {
        isOptimizing = true
        defer { isOptimizing = false }
        
        let startTime = Date()
        var output: String?
        var success = true
        
        switch action {
        case .flushDNS:
            try await flushDNSCache()
            
        case .clearRAM:
            try await clearInactiveMemory()
            
        case .rebuildLaunchServices:
            try await rebuildLaunchServices()
            
        case .cleanQuickLook:
            try await cleanQuickLook()
            
        case .cleanFonts:
            try await cleanFontCache()
        }
        
        return OptimizationResult(
            action: action,
            success: true,
            duration: Date().timeIntervalSince(startTime),
            output: output
        )
    }
    
    private func flushDNSCache() async throws {
        let process1 = Process()
        process1.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process1.arguments = ["-flushcache"]
        try process1.run()
        process1.waitUntilExit()
        
        let process2 = Process()
        process2.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process2.arguments = ["-HUP", "mDNSResponder"]
        try process2.run()
        process2.waitUntilExit()
    }
    
    private func clearInactiveMemory() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/purge")
        try process.run()
        process.waitUntilExit()
    }
    
    private func rebuildLaunchServices() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")
        process.arguments = ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]
        try process.run()
        process.waitUntilExit()
    }
}
```

### 2.4 CollectorBin

A virtual deletion staging area that allows users to review before permanent deletion:

```swift
// Tonic/Tonic/Services/CollectorBin.swift
@Observable
public final class CollectorBin: @unchecked Sendable {
    public var items: [BinItem] = []
    public var isEmptying = false
    public var isRestoring = false
    
    private let persistenceURL: URL
    private let fileManager = FileManager.default
    
    public init() {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let tonicDir = appSupport.appendingPathComponent("Tonic")
        let binDir = tonicDir.appendingPathComponent("CollectorBin")
        
        self.persistenceURL = binDir.appendingPathComponent("items.json")
        
        try? fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        loadFromDisk()
    }
    
    public func addToBin(atPaths paths: [String]) async -> (added: Int, failed: Int, totalSize: Int64) {
        var added = 0
        var failed = 0
        var totalSize: Int64 = 0
        
        for path in paths {
            if let item = createBinItem(from: path) {
                items.append(item)
                totalSize += item.fileSize
                added += 1
            } else {
                failed += 1
            }
        }
        
        saveToDisk()
        return (added, failed, totalSize)
    }
    
    public func restoreItems(itemIds: [UUID]) async -> BinRestorationResult {
        isRestoring = true
        defer { isRestoring = false }
        
        var restoredCount = 0
        var failedCount = 0
        
        for id in itemIds {
            if let index = items.firstIndex(where: { $0.id == id }) {
                let item = items[index]
                do {
                    try fileManager.moveItem(at: URL(fileURLWithPath: item.originalPath), to: URL(fileURLWithPath: item.originalPath))
                    items.remove(at: index)
                    restoredCount += 1
                } catch {
                    failedCount += 1
                }
            }
        }
        
        saveToDisk()
        return BinRestorationResult(restored: restoredCount, failed: failedCount)
    }
    
    public func emptyBin(confirm: Bool) async -> EmptyBinResult {
        guard confirm else {
            return EmptyBinResult(deleted: 0, failed: 0, bytesFreed: 0)
        }
        
        isEmptying = true
        defer { isEmptying = false }
        
        var deleted = 0
        var failed = 0
        var bytesFreed: Int64 = 0
        
        for item in items {
            let url = URL(fileURLWithPath: item.originalPath)
            do {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                let fileSize = Int64(resourceValues.fileSize ?? 0)
                
                if fileManager.fileExists(atPath: item.originalPath) {
                    try fileManager.removeItem(at: url)
                    deleted += 1
                    bytesFreed += fileSize
                }
            } catch {
                failed += 1
            }
        }
        
        items.removeAll()
        saveToDisk()
        
        return EmptyBinResult(deleted: deleted, failed: failed, bytesFreed: bytesFreed)
    }
    
    private func createBinItem(from path: String) -> BinItem? {
        let url = URL(fileURLWithPath: path)
        guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
            return nil
        }
        
        let fileName = url.lastPathComponent
        let fileSize = Int64(resourceValues.fileSize ?? 0)
        let lastModified = resourceValues.contentModificationDate ?? Date()
        let isDirectory = resourceValues.isDirectory
        
        let itemType: BinItemType
        if isDirectory {
            itemType = .directory
        } else if fileName.hasSuffix(".app") {
            itemType = .application
        } else if fileName.hasSuffix(".log") {
            itemType = .log
        } else {
            itemType = .file
        }
        
        return BinItem(
            id: UUID(),
            originalPath: path,
            fileName: fileName,
            fileSize: fileSize,
            itemType: itemType,
            addedDate: lastModified,
            thumbnailData: nil,
            tags: []
        )
    }
    
    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        if let data = try? encoder.encode(items) {
            try? data.write(to: persistenceURL)
        }
    }
    
    private func loadFromDisk() {
        if let data = try? Data(contentsOf: persistenceURL) {
            let decoder = JSONDecoder()
            items = (try? decoder.decode([BinItem].self, from: data)) ?? []
        }
    }
}

public struct BinItem: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public let originalPath: String
    public let fileName: String
    public let fileSize: Int64
    public let itemType: BinItemType
    public let addedDate: Date
    public var thumbnailData: Data?
    public var tags: [String]
    
    public var formattedSize: String {
        ByteCountFormatter.string(fromBytes: fileSize, countStyle: .file)
    }
}

public enum BinItemType: String, Sendable, Codable, CaseIterable {
    case file, directory, application, archive, cache, log, temp
}
```

---

## 3. Monitoring Layer

### 3.1 WidgetDataManager

The WidgetDataManager aggregates system monitoring data from multiple sources:

```swift
// Tonic/Tonic/Services/WidgetDataManager.swift
@MainActor
@Observable
public final class WidgetDataManager {
    public static let shared = WidgetDataManager()
    
    public private(set) var cpuData: CPUData?
    public private(set) var memoryData: MemoryData?
    public private(set) var diskVolumes: [DiskVolumeData] = []
    public private(set) var networkData: NetworkData?
    public private(set) var gpuData: GPUData?
    public private(set) var batteryData: BatteryData?
    public private(set) var weatherData: WeatherData?
    
    public var updateInterval: TimeInterval = 2.0
    private var monitoringTask: Task<Void, Never>?
    private var isMonitoring = false
    
    public struct CPUData: Sendable {
        public let totalUsage: Double
        public let perCoreUsage: [Double]
        public let activeProcesses: Int
        public let threadCount: Int
        public let timestamp: Date
    }
    
    public struct MemoryData: Sendable {
        public let usedBytes: UInt64
        public let totalBytes: UInt64
        public let pressure: MemoryPressure
        public let compressedBytes: UInt64
        public let swapBytes: UInt64
        public let timestamp: Date
        
        public var usagePercentage: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(usedBytes) / Double(totalBytes) * 100
        }
    }
    
    public struct DiskVolumeData: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let path: String
        public let usedBytes: UInt64
        public let totalBytes: UInt64
        public let isBootVolume: Bool
        public let isRemovable: Bool
        
        public var usagePercentage: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(usedBytes) / Double(totalBytes) * 100
        }
    }
    
    public struct NetworkData: Sendable {
        public let uploadBytesPerSecond: UInt64
        public let downloadBytesPerSecond: UInt64
        public let isConnected: Bool
        public let connectionType: ConnectionType
        public let ssid: String?
        public let ipAddress: String?
        public let timestamp: Date
        
        public var formattedUpload: String {
            ByteCountFormatter.string(fromBytes: Int64(uploadBytesPerSecond), countStyle: .file) + "/s"
        }
        
        public var formattedDownload: String {
            ByteCountFormatter.string(fromBytes: Int64(downloadBytesPerSecond), countStyle: .file) + "/s"
        }
    }
    
    public struct GPUData: Sendable {
        public let usagePercentage: Double
        public let usedMemoryBytes: UInt64
        public let totalMemoryBytes: UInt64
        public let temperature: Double?
        public let timestamp: Date
    }
    
    public struct BatteryData: Sendable {
        public let isPresent: Bool
        public let isCharging: Bool
        public let chargePercentage: Double
        public let health: BatteryHealth
        public let timeRemaining: TimeInterval?
        public let cycleCount: Int
        public let temperature: Double?
        public let timestamp: Date
    }
    
    public enum ConnectionType: String, Sendable {
        case ethernet
        case wifi
        case cellular
        case none
    }
    
    public enum MemoryPressure: String, CaseIterable, Sendable {
        case normal = "Normal"
        case warning = "Warning"
        case critical = "Critical"
        
        public var color: String {
            switch self {
            case .normal: return "green"
            case .warning: return "orange"
            case .critical: return "red"
            }
        }
    }
    
    public enum BatteryHealth: String, CaseIterable, Sendable {
        case good = "Good"
        case fair = "Fair"
        case poor = "Poor"
        case unknown = "Unknown"
    }
    
    private init() {}
    
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        
        monitoringTask = Task { [weak self] in
            guard let self = self else { return }
            
            while self.isMonitoring {
                self.updateAllData()
                try? await Task.sleep(nanoseconds: UInt64(self.updateInterval * 1_000_000_000))
            }
        }
    }
    
    public func stopMonitoring() {
        isMonitoring = false
        monitoringTask?.cancel()
        monitoringTask = nil
    }
    
    private func updateAllData() {
        Task {
            cpuData = await getCPUUsage()
            memoryData = await getMemoryUsage()
            diskVolumes = await getDiskUsage()
            networkData = await getNetworkStats()
            gpuData = await getGPUStats()
            batteryData = await getBatteryInfo()
        }
    }
    
    private func getCPUUsage() async -> CPUData? {
        var cpuInfo: processor_cpu_load_info_data_t?
        var count: mach_msg_type_number_t = mach_msg_type_number_t(MemoryLayout<processor_cpu_load_info_data_t>.size)
        
        let result = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, $0, &count)
            }
        }
        
        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return nil
        }
        
        var totalUsage: Double = 0
        var perCoreUsage: [Double] = []
        
        let numCores = Int(count / MemoryLayout<processor_cpu_load_info_data_t>.size)
        
        for core in 0..<numCores {
            let coreOffset = core * MemoryLayout<processor_cpu_load_info_data_t>.size
            let user = UInt64(info[coreOffset + CPU_STATE_USER])
            let system = UInt64(info[coreOffset + CPU_STATE_SYSTEM])
            let nice = UInt64(info[coreOffset + CPU_STATE_NICE])
            let idle = UInt64(info[coreOffset + CPU_STATE_IDLE])
            let total = user + system + nice + idle
            
            let usage = total > 0 ? Double(user + system + nice) / Double(total) * 100 : 0
            perCoreUsage.append(usage)
            totalUsage += usage
        }
        
        return CPUData(
            totalUsage: totalUsage / Double(numCores),
            perCoreUsage: perCoreUsage,
            activeProcesses: await getProcessCount(),
            threadCount: await getThreadCount(),
            timestamp: Date()
        )
    }
    
    private func getMemoryUsage() async -> MemoryData? {
        var machPort: mach_port_t = 0
        var size: UInt32 = UInt32(MemoryLayout<vm_statistics64_data_t>.size)
        
        let result = host_statistics64(
            mach_host_self(),
            HOST_VM_INFO64,
            withUnsafeMutablePointer(to: &machPort) {
                $0.withMemoryRebound(to: vm_statistics64_t.self, capacity: 1) {
                    host_info64(mach_port, HOST_VM_INFO64, $0, &size)
                }
            }
        )
        
        guard result == KERN_SUCCESS else { return nil }
        
        var stats = vm_statistics64_data_t()
        withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        
        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        let total = stats.wire_count + stats.active_count + stats.inactive_count + stats.free_count
        let used = (stats.wire_count + stats.active_count + stats.inactive_count) * pageSize
        let totalMemory = total * pageSize
        let compressed = stats.compressor_page_count * pageSize
        let swapTotal = UInt64(stats.virtual_page_count - total) * pageSize
        
        let pressure: MemoryPressure
        if stats.compressor_page_count > 0 {
            pressure = stats.free_count < (total / 4) ? .critical : .warning
        } else {
            pressure = stats.free_count < (total / 5) ? .warning : .normal
        }
        
        return MemoryData(
            usedBytes: used,
            totalBytes: totalMemory,
            pressure: pressure,
            compressedBytes: compressed,
            swapBytes: swapTotal,
            timestamp: Date()
        )
    }
    
    private func getDiskUsage() async -> [DiskVolumeData] {
        var volumes: [DiskVolumeData] = []
        
        let paths = ["/", "/Volumes"]
        for path in paths {
            if let stat = try? DiskScanner.statfs(path) {
                volumes.append(DiskVolumeData(
                    id: UUID().uuidString,
                    name: stat.f_mntonname,
                    path: path,
                    usedBytes: UInt64(stat.f_blocks - stat.f_bfree) * UInt64(stat.f_bsize),
                    totalBytes: UInt64(stat.f_blocks) * UInt64(stat.f_bsize),
                    isBootVolume: path == "/",
                    isRemovable: false
                ))
            }
        }
        
        return volumes
    }
    
    private func getNetworkStats() async -> NetworkData? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }
        
        var downloadDelta: UInt64 = 0
        var uploadDelta: UInt64 = 0
        var primaryInterface: String?
        
        var prevStats: [String: (in: UInt64, out: UInt64)] = [:]
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let name = String(validatingUTF8: interface.ifa_name) else { continue }
            
            if name == "en0" || name == "en1" {
                if let data = interface.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                    let inputBytes = UInt64(networkData.ifi_ibytes)
                    let outputBytes = UInt64(networkData.ifi_obytes)
                    
                    if let prev = previousNetworkStats[name] {
                        downloadDelta = inputBytes - prev.in
                        uploadDelta = outputBytes - prev.out
                    }
                    
                    previousNetworkStats[name] = (inputBytes, outputBytes)
                    primaryInterface = name
                }
            }
        }
        
        let (connectionType, ssid) = await getWifiInfo()
        
        return NetworkData(
            uploadBytesPerSecond: uploadDelta * 8,
            downloadBytesPerSecond: downloadDelta * 8,
            isConnected: true,
            connectionType: connectionType,
            ssid: ssid,
            ipAddress: getIPAddress(),
            timestamp: Date()
        )
    }
}
```

### 3.2 WeatherService

Weather data using Open-Meteo API (free, no API key required):

```swift
// Tonic/Tonic/Services/WeatherService.swift
@MainActor
@Observable
public final class WeatherService: NSObject, @unchecked Sendable {
    public var currentWeather: WeatherResponse?
    public var savedLocations: [WeatherLocation] = []
    public var temperatureUnit: TemperatureUnit = .auto
    public var isLoading = false
    public var lastError: String?
    
    private let locationManager = CLLocationManager()
    private var updateTimer: Timer?
    private let session = URLSession.shared
    
    public enum TemperatureUnit: String, CaseIterable, Codable, Sendable {
        case celsius = "celsius"
        case fahrenheit = "fahrenheit"
        case auto = "auto"
        
        public var symbol: String {
            switch self {
            case .celsius: return "°C"
            case .fahrenheit: return "°F"
            case .auto: return ""
            }
        }
    }
    
    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    
    public func startUpdates() {
        locationManager.requestWhenInUseAuthorization()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateWeather()
            }
        }
    }
    
    public func stopUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    public func updateWeather() {
        guard let location = getCurrentLocation() else {
            lastError = "Location not available"
            return
        }
        
        isLoading = true
        
        let url = URL(string: "https://api.open-meteo.com/v1/forecast")!
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,rain,showers,snowfall,weather_code,cloud_cover,wind_speed_10m,wind_direction_10m,uv_index"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,precipitation_probability"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]
        
        Task {
            do {
                let (data, _) = try await session.data(from: components.url!)
                let decoder = JSONDecoder()
                let response = try decoder.decode(WeatherResponse.self, from: data)
                self.currentWeather = response
                self.isLoading = false
            } catch {
                self.lastError = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    public func formatTemperature(_ celsius: Double) -> String {
        switch temperatureUnit {
        case .celsius:
            return String(format: "%.0f°C", celsius)
        case .fahrenheit:
            return String(format: "%.0f°F", celsius * 9/5 + 32)
        case .auto:
            let locale = Locale.current
            if locale.measurementSystem == .imperial {
                return String(format: "%.0f°F", celsius * 9/5 + 32)
            }
            return String(format: "%.0f°C", celsius)
        }
    }
    
    private func getCurrentLocation() -> (latitude: Double, longitude: Double)? {
        guard let location = locationManager.location else { return nil }
        return (location.coordinate.latitude, location.coordinate.longitude)
    }
}

extension WeatherService: CLLocationManagerDelegate {
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            updateWeather()
        default:
            lastError = "Location permission denied"
        }
    }
}

// MARK: - Weather Models
public struct WeatherResponse: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let timezone: String
    public let current: CurrentWeather
    public let hourly: HourlyWeather?
    public let daily: DailyWeather?
    
    public struct CurrentWeather: Codable, Sendable {
        public let time: Date
        public let temperature: Double
        public let apparentTemperature: Double?
        public let relativeHumidity: Int?
        public let isDay: Int?
        public let weatherCode: Int?
        public let cloudCover: Int?
        public let windSpeed: Double?
        public let windDirection: Int?
        public let uvIndex: Double?
        public let precipitation: Double?
    }
}

public enum WeatherCondition: String, Codable, Sendable {
    case clear = "clear"
    case cloudy = "cloudy"
    case partlyCloudy = "partly_cloudy"
    case rain = "rain"
    case drizzle = "drizzle"
    case snow = "snow"
    case thunderstorm = "thunderstorm"
    case fog = "fog"
    case mist = "mist"
    case unknown = "unknown"
    
    public var sfSymbol: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .cloudy: return "cloud.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .rain: return "cloud.rain.fill"
        case .drizzle: return "cloud.drizzle.fill"
        case .snow: return "cloud.snow.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .fog, .mist: return "cloud.fog.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}
```

### 3.3 NotificationRuleEngine

Rule-based notification system:

```swift
// Tonic/Tonic/Services/NotificationRuleEngine.swift
@MainActor
@Observable
public final class NotificationRuleEngine: NSObject, @unchecked Sendable {
    public var rules: [NotificationRule] = []
    public var triggerHistory: [RuleTrigger] = []
    public var isActive = false
    
    private var evaluationTimer: Timer?
    private let notificationCenter = UNUserNotificationCenter.current()
    
    public struct NotificationRule: Identifiable, Codable, Sendable {
        public let id: UUID
        public var name: String
        public var isEnabled: Bool
        public var metric: RuleMetric
        public var condition: RuleCondition
        public var threshold: Double
        public var cooldownMinutes: Int
        public var lastTriggered: Date?
        public var isSystemRule: Bool
        
        public init(
            id: UUID = UUID(),
            name: String,
            isEnabled: Bool = true,
            metric: RuleMetric,
            condition: RuleCondition,
            threshold: Double,
            cooldownMinutes: Int = 15,
            lastTriggered: Date? = nil,
            isSystemRule: Bool = false
        ) {
            self.id = id
            self.name = name
            self.isEnabled = isEnabled
            self.metric = metric
            self.condition = condition
            self.threshold = threshold
            self.cooldownMinutes = cooldownMinutes
            self.lastTriggered = lastTriggered
            self.isSystemRule = isSystemRule
        }
        
        public var isInCooldown: Bool {
            guard let lastTriggered = lastTriggered else { return false }
            return Date().timeIntervalSince(lastTriggered) < TimeInterval(cooldownMinutes * 60)
        }
        
        public static let presetRules: [NotificationRule] = [
            NotificationRule(
                name: "High CPU Usage",
                metric: .cpuUsage,
                condition: .greaterThan,
                threshold: 80,
                cooldownMinutes: 15,
                isSystemRule: true
            ),
            NotificationRule(
                name: "Low Disk Space",
                metric: .diskSpace,
                condition: .lessThan,
                threshold: 15,
                cooldownMinutes: 60,
                isSystemRule: true
            ),
            NotificationRule(
                name: "Critical Memory Pressure",
                metric: .memoryPressure,
                condition: .equals,
                threshold: 2,
                cooldownMinutes: 15,
                isSystemRule: true
            )
        ]
    }
    
    public enum RuleMetric: String, CaseIterable, Codable, Sendable {
        case cpuUsage
        case memoryPressure
        case diskSpace
        case networkDown
        case weatherTemp
        
        public var displayName: String {
            switch self {
            case .cpuUsage: return "CPU Usage"
            case .memoryPressure: return "Memory Pressure"
            case .diskSpace: return "Disk Space"
            case .networkDown: return "Network"
            case .weatherTemp: return "Temperature"
            }
        }
        
        public var unit: String {
            switch self {
            case .cpuUsage, .memoryPressure, .diskSpace: return "%"
            case .networkDown: return ""
            case .weatherTemp: return "°C"
            }
        }
    }
    
    public enum RuleCondition: String, CaseIterable, Codable, Sendable {
        case greaterThan
        case lessThan
        case equals
        
        public var symbol: String {
            switch self {
            case .greaterThan: return ">"
            case .lessThan: return "<"
            case .equals: return "="
            }
        }
    }
    
    public struct RuleTrigger: Identifiable, Sendable {
        public let id: UUID
        public let ruleId: UUID
        public let ruleName: String
        public let metric: RuleMetric
        public let value: Double
        public let triggeredAt: Date
        
        public init(rule: NotificationRule, value: Double) {
            self.id = UUID()
            self.ruleId = rule.id
            self.ruleName = rule.name
            self.metric = rule.metric
            self.value = value
            self.triggeredAt = Date()
        }
    }
    
    public func start() {
        guard !isActive else { return }
        isActive = true
        
        loadRules()
        loadTriggerHistory()
        
        evaluationTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateRules()
            }
        }
        
        requestNotificationPermission()
    }
    
    public func stop() {
        isActive = false
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }
    
    public func evaluateRules() {
        guard isActive else { return }
        
        let widgetData = WidgetDataManager.shared
        
        for rule in rules where rule.isEnabled && !rule.isInCooldown {
            let currentValue = getCurrentValue(for: rule.metric)
            
            if shouldTrigger(rule: rule, currentValue: currentValue) {
                triggerRule(rule, value: currentValue)
            }
        }
    }
    
    private func getCurrentValue(for metric: RuleMetric) -> Double {
        switch metric {
        case .cpuUsage:
            return WidgetDataManager.shared.cpuData?.totalUsage ?? 0
        case .memoryPressure:
            let pressure = WidgetDataManager.shared.memoryData?.pressure
            switch pressure {
            case .normal: return 0
            case .warning: return 1
            case .critical: return 2
            case .none: return 0
            }
        case .diskSpace:
            return WidgetDataManager.shared.diskVolumes.first { $0.isBootVolume }?.usagePercentage ?? 0
        case .networkDown:
            return WidgetDataManager.shared.networkData?.isConnected == true ? 0 : 1
        case .weatherTemp:
            return WidgetDataManager.shared.weatherData?.temperature ?? 0
        }
    }
    
    private func shouldTrigger(rule: NotificationRule, currentValue: Double) -> Bool {
        switch rule.condition {
        case .greaterThan:
            return currentValue > rule.threshold
        case .lessThan:
            return currentValue < rule.threshold
        case .equals:
            return abs(currentValue - rule.threshold) < 0.01
        }
    }
    
    private func triggerRule(_ rule: NotificationRule, value: Double) {
        let trigger = RuleTrigger(rule: rule, value: value)
        triggerHistory.insert(trigger, at: 0)
        
        if triggerHistory.count > 100 {
            triggerHistory.removeLast()
        }
        
        var mutableRule = rule
        mutableRule.lastTriggered = Date()
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = mutableRule
        }
        
        sendNotification(for: trigger)
        saveRules()
    }
    
    private func sendNotification(for trigger: RuleTrigger) {
        let content = UNMutableNotificationContent()
        content.title = trigger.ruleName
        content.subtitle = "\(trigger.metric.displayName): \(String(format: "%.1f", trigger.value))\(trigger.metric.unit)"
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: trigger.id.uuidString,
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request)
    }
}
```

---

## 4. Menu Bar Widgets

### 4.1 Widget Architecture

Each widget manages its own `NSStatusItem` independently:

```swift
// Tonic/Tonic/MenuBarWidgets/WidgetStatusItem.swift
@MainActor
public final class WidgetStatusItem: ObservableObject {
    private(set) var statusItem: NSStatusItem?
    private(set) var hostingController: NSHostingController<AnyView>?
    
    public var isVisible: Bool = false {
        didSet {
            statusItem?.isVisible = isVisible
        }
    }
    
    public init() {}
    
    public func createStatusItem<Content: View>(
        widgetType: WidgetType,
        displayMode: WidgetDisplayMode,
        @ViewBuilder content: @escaping () -> Content
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: .variable)
        
        let view = content()
        hostingController = NSHostingController(rootView: AnyView(view))
        hostingController?.view.translatesAutoresizingMaskIntoConstraints = false
        
        statusItem?.button?.addSubview(hostingController!.view)
        
        NSLayoutConstraint.activate([
            hostingController!.view.leadingAnchor.constraint(equalTo: statusItem!.button!.leadingAnchor),
            hostingController!.view.trailingAnchor.constraint(equalTo: statusItem!.button!.trailingAnchor),
            hostingController!.view.topAnchor.constraint(equalTo: statusItem!.button!.topAnchor),
            hostingController!.view.bottomAnchor.constraint(equalTo: statusItem!.button!.bottomAnchor)
        ])
        
        statusItem?.button?.action = #selector(statusItemClicked)
        statusItem?.button?.target = self
    }
    
    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        
        if let popover = getPopover(for: button) {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    
    private func getPopover(for view: NSView) -> NSPopover? {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: getDetailView(for: widgetType))
        return popover
    }
    
    public func updateContent<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        hostingController?.rootView = AnyView(content())
    }
}
```

### 4.2 CPU Widget

```swift
// Tonic/Tonic/MenuBarWidgets/CPUWidgetView.swift
import SwiftUI

struct CPUWidgetView: View {
    @State private var cpuData: WidgetDataManager.CPUData?
    @State private var history: [Double] = []
    
    private let maxHistoryPoints = 30
    
    var body: some View {
        VStack(spacing: 2) {
            if let data = cpuData {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12))
                        .foregroundColor(accentColor)
                    
                    Text("\(Int(data.totalUsage))%")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(textColor)
                }
                
                if showSparkline {
                    SparklineView(data: history, color: accentColor)
                        .frame(height: 16)
                }
            } else {
                ProgressView()
                    .scaleEffect(0.5)
            }
        }
        .padding(.horizontal, showSparkline ? 8 : 4)
        .padding(.vertical, 4)
        .onAppear {
            startMonitoring()
        }
    }
    
    private var accentColor: Color {
        guard let data = cpuData else { return .gray }
        if data.totalUsage > 80 { return .red }
        if data.totalUsage > 50 { return .orange }
        return .green
    }
    
    private var textColor: Color {
        guard let data = cpuData else { return .secondary }
        if data.totalUsage > 80 { return .red }
        return .primary
    }
    
    private var showSparkline: Bool {
        WidgetPreferences.shared.widgetConfigs.first { $0.type == .cpu }?.displayMode == .detailed
    }
    
    private func startMonitoring() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            updateData()
        }
    }
    
    private func updateData() {
        cpuData = WidgetDataManager.shared.cpuData
        
        if let usage = cpuData?.totalUsage {
            history.append(usage)
            if history.count > maxHistoryPoints {
                history.removeFirst()
            }
        }
    }
}

struct SparklineView: View {
    let data: [Double]
    let color: Color
    
    var body: some View {
        GeometryReader { geometry in
            if data.count >= 2 {
                Path { path in
                    let stepX = geometry.size.width / CGFloat(data.count - 1)
                    let maxValue = data.max() ?? 100
                    let minValue = data.min() ?? 0
                    let range = maxValue - minValue > 0 ? maxValue - minValue : 100
                    
                    for (index, value) in data.enumerated() {
                        let x = CGFloat(index) * stepX
                        let normalizedY = (value - minValue) / range
                        let y = geometry.size.height * (1 - normalizedY)
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: 1.5)
            }
        }
    }
}
```

---

## 5. User Interface

### 5.1 DashboardView

The main dashboard with health score and quick actions:

```swift
// Tonic/Tonic/Views/DashboardView.swift
struct DashboardView: View {
    @StateObject private var smartScanManager = SmartScanManager()
    @State private var showSmartScan = false
    @State private var showDeepClean = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.lg) {
                healthScoreSection
                quickActionsSection
                quickStatsSection
                recommendationsSection
                activitySection
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .background(DesignTokens.Colors.background)
    }
    
    private var healthScoreSection: some View {
        Card {
            VStack(spacing: DesignTokens.Spacing.md) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("System Health")
                            .font(DesignTokens.Typography.headlineMedium)
                            .foregroundColor(DesignTokens.Colors.text)
                        
                        Text(healthRatingText)
                            .font(DesignTokens.Typography.bodyLarge)
                            .foregroundColor(DesignTokens.Colors.textSecondary)
                    }
                    
                    Spacer()
                    
                    ZStack {
                        Circle()
                            .stroke(DesignTokens.Colors.surfaceElevated, lineWidth: 8)
                            .frame(width: 100, height: 100)
                        
                        Circle()
                            .trim(from: 0, to: CGFloat(smartScanManager.healthScore) / 100)
                            .stroke(healthScoreColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .frame(width: 100, height: 100)
                            .rotationEffect(.degrees(-90))
                        
                        Text("\(smartScanManager.healthScore)")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(healthScoreColor)
                    }
                }
            }
        }
    }
    
    private var healthScoreColor: Color {
        switch smartScanManager.healthScore {
        case 80...100: return DesignTokens.Colors.progressLow
        case 60..<80: return DesignTokens.Colors.warning
        default: return DesignTokens.Colors.error
        }
    }
    
    private var healthRatingText: String {
        switch smartScanManager.healthScore {
        case 80...100: return "Your Mac is in excellent condition"
        case 60..<80: return "Some cleanup recommended"
        default: return "Immediate attention needed"
        }
    }
    
    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Quick Actions")
                .font(DesignTokens.Typography.titleMedium)
                .foregroundColor(DesignTokens.Colors.text)
            
            HStack(spacing: DesignTokens.Spacing.md) {
                QuickActionButton(
                    title: "Smart Scan",
                    icon: "sparkles",
                    color: DesignTokens.Colors.accent
                ) {
                    showSmartScan = true
                }
                
                QuickActionButton(
                    title: "Deep Clean",
                    icon: "trash.fill",
                    color: DesignTokens.Colors.error
                ) {
                    showDeepClean = true
                }
                
                QuickActionButton(
                    title: "Optimize",
                    icon: "bolt.fill",
                    color: DesignTokens.Colors.warning
                ) {
                    // Trigger optimization
                }
                
                QuickActionButton(
                    title: "Analyze Disk",
                    icon: "externaldrive.fill",
                    color: DesignTokens.Colors.success
                ) {
                    // Navigate to disk analysis
                }
            }
        }
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                    .foregroundColor(color)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.text)
            }
            .frame(maxWidth: .infinity)
            .padding(DesignTokens.Spacing.md)
            .background(isHovered ? color.opacity(0.1) : DesignTokens.Colors.surface)
            .cornerRadius(DesignTokens.CornerRadius.large)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}
```

### 5.2 DiskMapView

Treemap visualization for disk usage:

```swift
// Tonic/Tonic/Views/DiskMapView.swift
struct DiskMapView: View {
    @State private var rootNode: TreemapNode?
    @State private var selectedNode: TreemapNode?
    @State private var hoveredNode: TreemapNode?
    @State private var showLegend = true
    
    var body: some View {
        VStack(spacing: 0) {
            if let node = rootNode {
                GeometryReader { geometry in
                    TreemapLayout(node: node, size: geometry.size)
                        .onTapGesture {
                            // Handle selection
                        }
                }
                .frame(minHeight: 400)
                
                if showLegend {
                    legendView
                        .padding(DesignTokens.Spacing.md)
                }
            } else {
                ProgressView("Scanning disk...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    
    private var legendView: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            ForEach(FileTypeCategory.commonCategories) { category in
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Circle()
                        .fill(category.color)
                        .frame(width: 12, height: 12)
                    
                    Text(category.name)
                        .font(.caption)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }
        }
    }
}

struct TreemapNode: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
    let type: FileTypeCategory
    var children: [TreemapNode] = []
    
    var totalSize: Int64 {
        children.isEmpty ? size : children.reduce(0) { $0 + $1.totalSize }
    }
}

struct TreemapLayout: View {
    let node: TreemapNode
    let size: CGSize
    
    var body: some View {
        if node.children.isEmpty {
            Rectangle()
                .fill(node.type.color)
                .overlay(
                    VStack {
                        Text(node.name)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundColor(.white)
                        
                        Text(formatSize(node.size))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                )
                .frame(width: rect.width, height: rect.height)
                .onHover { hovering in
                    // Show tooltip
                }
        } else {
            ForEach(node.children) { child in
                TreemapLayout(node: child, size: childSize(for: child))
            }
        }
    }
    
    private func rect(for node: TreemapNode) -> CGRect {
        let scale = size.width * size.height / CGFloat(rootTotalSize)
        let nodeArea = CGFloat(node.totalSize) * scale
        
        let width = sqrt(nodeArea * (size.width / size.height))
        let height = nodeArea / width
        
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}
```

---

## 6. App Management

### 6.1 AppInventoryView

Comprehensive app inventory with filtering and batch operations:

```swift
// Tonic/Tonic/Views/AppInventoryView.swift
struct AppInventoryView: View {
    @StateObject private var inventoryService = AppInventoryService()
    @State private var selectedTab: ItemType = .apps
    @State private var searchText = ""
    @State private var selectedAppIDs: Set<UUID> = []
    @State private var showUninstallConfirmation = false
    
    enum ItemType: String, CaseIterable, Identifiable {
        case apps = "Apps"
        case extensions = "Extensions"
        case prefPanes = "Pref Panes"
        case quickLook = "Quick Look"
        case spotlight = "Spotlight"
        case frameworks = "Frameworks"
        case systemUtilities = "System Utilities"
        case loginItems = "Login Items"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .apps: return "app.fill"
            case .extensions: return "puzzlepiece.extension.fill"
            case .prefPanes: return "switch.2"
            case .quickLook: return "photo.on.rectangle"
            case .spotlight: return "magnifyingglass"
            case .framework  return "shippingbox.fill"
            case .systemUtilities: return "wrench.and.screwdriver.fill"
            case .loginItems: return "person.crop.circle"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            tabSelector
            searchAndFilterBar
            appListView
            actionBar
        }
    }
    
    private var tabSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(ItemType.allCases) { tab in
                    TabButton(
                        title: tab.rawValue,
                        icon: tab.icon,
                        isSelected: selectedTab == tab
                    ) {
                        selectedTab = tab
                        inventoryService.selectedTab = tab
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
        .background(DesignTokens.Colors.surface)
    }
    
    private var searchAndFilterBar: some View {
        HStack {
            SearchBar(text: $searchText)
                .frame(maxWidth: 300)
            
            Spacer()
            
            SortMenu(selection: $inventoryService.sortOption)
            
            QuickFilterMenu(selection: $inventoryService.quickFilterCategory)
        }
        .padding(DesignTokens.Spacing.md)
    }
    
    private var appListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredApps) { app in
                    AppRow(
                        app: app,
                        isSelected: selectedAppIDs.contains(app.id),
                        onSelect: {
                            if selectedAppIDs.contains(app.id) {
                                selectedAppIDs.remove(app.id)
                            } else {
                                selectedAppIDs.insert(app.id)
                            }
                        },
                        onUninstall: {
                            showUninstallConfirmation = true
                        }
                    )
                }
            }
        }
    }
    
    private var filteredApps: [AppMetadata] {
        var apps = inventoryService.apps
        
        // Filter by tab
        apps = apps.filter { $0.itemType == selectedTab.rawValue }
        
        // Filter by search
        if !searchText.isEmpty {
            apps = apps.filter {
                $0.appName.localizedCaseInsensitiveContains(searchText) ||
                $0.bundleIdentifier.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Sort
        switch inventoryService.sortOption {
        case .nameAscending:
            apps.sort { $0.appName < $1.appName }
        case .sizeDescending:
            apps.sort { $0.totalSize > $1.totalSize }
        case .lastUsed:
            apps.sort { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        default:
            break
        }
        
        return apps
    }
}

struct AppRow: View {
    let app: AppMetadata
    let isSelected: Bool
    let onSelect: () -> Void
    let onUninstall: () -> Void
    
    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? DesignTokens.Colors.accent : DesignTokens.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            
            if let iconImage = NSImage(contentsOf: app.path.appendingPathComponent("Contents/Resources/AppIcon.icns")) {
                Image(nsImage: iconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.fill")
                    .font(.title2)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.body)
                    .foregroundColor(DesignTokens.Colors.text)
                
                Text(app.bundleIdentifier)
                    .font(.caption)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
            
            Spacer()
            
            Text(ByteCountFormatter.string(fromBytes: app.totalSize, countStyle: .file))
                .font(.caption)
                .foregroundColor(DesignTokens.Colors.textSecondary)
            
            if app.isProtected {
                Image(systemName: "lock.fill")
                    .foregroundColor(DesignTokens.Colors.warning)
            }
            
            Button(action: onUninstall) {
                Image(systemName: "trash")
                    .foregroundColor(DesignTokens.Colors.error)
            }
            .buttonStyle(.plain)
            .disabled(app.isProtected)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(isSelected ? DesignTokens.Colors.accent.opacity(0.1) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
```

---

## 7. Permissions and Security

### 7.1 PermissionManager

Manages system permissions required for full functionality:

```swift
// Tonic/Tonic/Services/PermissionManager.swift
@Observable
public final class PermissionManager: @unchecked Sendable {
    public var permissionStatuses: [TonicPermission: PermissionStatus] = [:]
    
    public enum TonicPermission: String, CaseIterable, Sendable {
        case fullDiskAccess
        case accessibility
        case notifications
        case location
        case microphone
        case camera
        
        public var description: String {
            switch self {
            case .fullDiskAccess: return "Full Disk Access to scan and clean all files"
            case .accessibility: return "Accessibility to automate system tasks"
            case .notifications: return "Send notifications for scan results and alerts"
            case .location: return "Access location for weather widget"
            case .microphone: return "Microphone access"
            case .camera: return "Camera access"
            }
        }
        
        public var systemSetting: String {
            switch self {
            case .fullDiskAccess: return "Privacy_FullDiskAccess"
            case .accessibility: return "Privacy_Accessibility"
            case .notifications: return "NOTIFICATIONS"
            case .location: return "Privacy_LocationServices"
            case .microphone: return "Privacy_MicrophoneUsageDescription"
            case .camera: return "Privacy_CameraUsageDescription"
            }
        }
    }
    
    public enum PermissionStatus: String, Sendable {
        case notDetermined
        case denied
        case authorized
        
        public var isAuthorized: Bool {
            self == .authorized
        }
    }
    
    public init() {
        checkAllPermissions()
    }
    
    public func checkAllPermissions() async {
        for permission in TonicPermission.allCases {
            permissionStatuses[permission] = await checkPermission(permission)
        }
    }
    
    public func checkPermission(_ permission: TonicPermission) async -> PermissionStatus {
        switch permission {
        case .fullDiskAccess:
            return checkFullDiskAccess()
            
        case .accessibility:
            return AXIsProcessTrusted() ? .authorized : .notDetermined
            
        case .notifications:
            return await checkNotificationPermission()
            
        case .location:
            return checkLocationPermission()
            
        case .microphone, .camera:
            return .notDetermined
        }
    }
    
    private func checkFullDiskAccess() -> PermissionStatus {
        let testPaths = [
            "/Library/Application Support",
            NSHomeDirectory() + "/Library/Messages",
            NSHomeDirectory() + "/Library/Mail"
        ]
        
        for path in testPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.isReadableFile(atPath: url.path) {
                return .authorized
            }
        }
        
        return .denied
    }
    
    private func checkNotificationPermission() async -> PermissionStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        
        switch settings.authorizationStatus {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .notDetermined
        default:
            return .notDetermined
        }
    }
    
    public func requestFullDiskAccess() -> Bool {
        if let url = URL(string: "x-apple.systempreferences:com.apple.SecurityPrivacy_FullDiskAccess") {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }
    
    public func canUseFeature(_ feature: Feature) -> (allowed: Bool, reason: String?) {
        switch feature {
        case .diskScan:
            if permissionStatuses[.fullDiskAccess] != .authorized {
                return (false, "Full Disk Access is required to scan your disk")
            }
        case .appUninstall:
            if permissionStatuses[.fullDiskAccess] != .authorized {
                return (false, "Full Disk Access is required to uninstall apps")
            }
        case .systemOptimization:
            if permissionStatuses[.accessibility] != .authorized {
                return (false, "Accessibility access is required for system optimizations")
            }
        case .basicScan:
            // Basic scan works without full disk access
            break
        }
        
        return (true, nil)
    }
    
    public enum Feature {
        case diskScan
        case appUninstall
        case systemOptimization
        case basicScan
    }
}
```

### 7.2 PrivilegedHelperManager

Manages the privileged helper tool for root operations:

```swift
// Tonic/Tonic/Services/PrivilegedHelperManager.swift
@Observable
public final class PrivilegedHelperManager: NSObject {
    public var isHelperInstalled = false
    public var isHelperConnected = false
    public var installationStatus: String = "Not installed"
    
    private let helperBundleURL: URL
    private var connection: NSXPCConnection?
    
    public static let shared = PrivilegedHelperManager()
    
    public enum PrivilegedHelperError: Error, LocalizedError {
        case authorizationFailed
        case installationFailed(String)
        case notInstalled
        case communicationFailed(String)
        case operationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .authorizationFailed:
                return "Authorization failed"
            case .installationFailed(let reason):
                return "Installation failed: \(reason)"
            case .notInstalled:
                return "Privileged helper is not installed"
            case .communicationFailed(let reason):
                return "Communication failed: \(reason)"
            case .operationFailed(let reason):
                return "Operation failed: \(reason)"
            }
        }
    }
    
    private override init() {
        let bundlePath = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/com.tonicformac.app.helper")
        self.helperBundleURL = bundlePath
        super.init()
        checkInstallationStatus()
    }
    
    public func checkInstallationStatus() -> Bool {
        let helperPath = "/Library/PrivilegedHelperTools/com.tonicformac.app.helper"
        isHelperInstalled = FileManager.default.fileExists(atPath: helperPath)
        installationStatus = isHelperInstalled ? "Installed" : "Not installed"
        return isHelperInstalled
    }
    
    public func installHelper() async throws {
        guard let authRef = try? getAuthorizationRef() else {
            throw PrivilegedHelperError.authorizationFailed
        }
        
        let jobLabel = "com.tonicformac.app.helper"
        
        var jobDict: [String: Any] = [
            "Label": jobLabel,
            "Program": helperBundleURL.path,
            "ProgramArguments": [helperBundleURL.path],
            "MachServices": [jobLabel: true],
            "KeepAlive": false
        ]
        
        let (success, error) = SMJobSubmit(
            kSMDomainUserLaunch,
            jobDict as CFDictionary,
            authRef,
            nil
        )
        
        if !success {
            throw PrivilegedHelper(error?.localizedDescription ?? "Unknown error")
Error.installationFailed        }
        
        isHelperInstalled = true
        installationStatus = "Installed"
        try await establishConnection()
    }
    
    public func uninstallHelper() async throws {
        let jobLabel = "com.tonicformac.app.helper"
        
        guard let authRef = try? getAuthorizationRef() else {
            throw PrivilegedHelperError.authorizationFailed
        }
        
        let (success, error) = SMJobRemove(
            kSMDomainUserLaunch,
            jobLabel as CFString,
            authRef,
            false,
            nil
        )
        
        if !success {
            throw PrivilegedHelperError.installationFailed(error?.localizedDescription ?? "Unknown error")
        }
        
        isHelperInstalled = false
        isHelperConnected = false
        installationStatus = "Not installed"
    }
    
    public func establishConnection() async throws {
        guard isHelperInstalled else {
            throw PrivilegedHelperError.notInstalled
        }
        
        let serviceName = "com.tonicformac.app.helper"
        
        connection = NSXPCConnection(machServiceName: serviceName)
        connection?.remoteObjectInterface = NSXPCInterface(with: PrivilegedHelperProtocol.self)
        connection?.resume()
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if self.connection != nil {
                    self.isHelperConnected = true
                    continuation.resume()
                } else {
                    self.isHelperConnected = false
                    continuation.resume(throwing: PrivilegedHelperError.communicationFailed("Connection failed"))
                }
            }
        }
    }
    
    public func deleteFile(atPath path: String) async throws -> Bool {
        guard isHelperConnected else {
            throw PrivilegedHelperError.notInstalled
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            connection?.remoteObjectProxy?.deleteFile(atPath: path) { success in
                if success {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(throwing: PrivilegedHelperError.operationFailed("Delete failed"))
                }
            }
        }
    }
    
    private func getAuthorizationRef() throws -> AuthorizationRef? {
        var authRef: AuthorizationRef?
        var authStatus = AuthorizationCreate(nil, nil, [], &authRef)
        
        guard authStatus == errAuthorizationSuccess else {
            throw PrivilegedHelperError.authorizationFailed
        }
        
        var rights: AuthorizationRights = [
            AuthorizationItem(name: "system.privilege.admin", valueLength: 0, value: nil, flags: [])
        ]
        
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights]
        authStatus = AuthorizationCreate(&rights, nil, flags, &authRef)
        
        guard authStatus == errAuthorizationSuccess else {
            throw PrivilegedHelperError.authorizationFailed
        }
        
        return authRef
    }
}
```

---

## 8. Data Models

### 8.1 Scan Models

```swift
// Tonic/Tonic/Models/ScanResult.swift
public struct ScanResult: Identifiable, Codable {
    public let id: UUID
    public let timestamp: Date
    public let healthScore: Int
    public let junkFiles: JunkCategory
    public let performanceIssues: PerformanceCategory
    public let appIssues: AppIssueCategory
    public let privacyIssues: PrivacyCategory
    public let totalReclaimableSpace: Int64
    
    public var healthRating: HealthRating {
        switch healthScore {
        case 80...100: return .excellent
        case 60..<80: return .good
        case 40..<60: return .fair
        case 20..<40: return .poor
        default: return .critical
        }
    }
}

public enum HealthRating: String, Codable {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
    case critical = "Critical"
    
    public var color: String {
        switch self {
        case .excellent: return "green"
        case .good: return "blue"
        case .fair: return "orange"
        case .poor, .critical: return "red"
        }
    }
}

public struct JunkCategory: Codable {
    public var cacheFiles: Int64
    public var logFiles: Int64
    public var tempFiles: Int64
    public var trashItems: Int64
    public var browserCache: Int64
    public var languagePacks: Int64
    
    public var total: Int64 {
        cacheFiles + logFiles + tempFiles + trashItems + browserCache + languagePacks
    }
}

public struct AppIssueCategory: Codable {
    public var unusedApps: [AppMetadata]
    public var largeApps: [AppMetadata]
    public var duplicateApps: [DuplicateAppGroup]
    public var orphanedFiles: [OrphanedFile]
}

public struct OrphanedFile: Identifiable, Codable {
    public let id: UUID
    public let path: String
    public let fileName: String
    public let size: Int64
    public let appName: String
    public let orphanType: OrphanType
    public let lastModified: Date?
}

public enum OrphanType: String, CaseIterable, Codable {
    case appSupport = "Application Support"
    case cache = "Cache"
    case preferences = "Preferences"
    case container = "Container"
    case logs = "Logs"
    case launchAgent = "Launch Agent"
    case other = "Other"
}
```

### 8.2 Widget Configuration Models

```swift
// Tonic/Tonic/Models/WidgetConfiguration.swift
public enum WidgetType: String, CaseIterable, Identifiable, Codable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case disk = "Disk"
    case network = "Network"
    case weather = "Weather"
    case battery = "Battery"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "gpu"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "network"
        case .weather: return "cloud.sun"
        case .battery: return "battery.100"
        }
    }
    
    public var description: String {
        switch self {
        case .cpu: return "CPU usage and history"
        case .gpu: return "GPU memory (Apple Silicon)"
        case .memory: return "Memory usage and pressure"
        case .disk: return "Disk space usage"
        case .network: return "Network activity"
        case .weather: return "Current weather conditions"
        case .battery: return "Battery level and status"
        }
    }
}

public enum WidgetDisplayMode: String, CaseIterable, Identifiable, Codable {
    case compact = "Compact"
    case detailed = "Detailed"
    
    public var id: String { rawValue }
}

public enum WidgetAccentColor: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case blue = "Blue"
    case green = "Green"
    case orange = "Orange"
    case purple = "Purple"
    case yellow = "Yellow"
    
    public var id: String { rawValue }
    
    public var color: Color {
        switch self {
        case .system: return .accentColor
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        case .yellow: return .yellow
        }
    }
}

public enum WidgetUpdateInterval: String, CaseIterable, Identifiable, Codable {
    case power = "Power Saving"
    case balanced = "Balanced"
    case performance = "Performance"
    
    public var id: String { rawValue }
    
    public var seconds: TimeInterval {
        switch self {
        case .power: return 5.0
        case .balanced: return 2.0
        case .performance: return 1.0
        }
    }
}

public struct WidgetConfiguration: Codable, Identifiable, Sendable {
    public let id: UUID
    public var type: WidgetType
    public var isEnabled: Bool
    public var position: Int
    public var displayMode: WidgetDisplayMode
    public var showLabel: Bool
    public var valueFormat: WidgetValueFormat
    public var refreshInterval: WidgetUpdateInterval
    public var accentColor: WidgetAccentColor
    
    public init(
        id: UUID = UUID(),
        type: WidgetType,
        isEnabled: Bool = true,
        position: Int = 0,
        displayMode: WidgetDisplayMode = .compact,
        showLabel: Bool = true,
        valueFormat: WidgetValueFormat = .percentage,
        refreshInterval: WidgetUpdateInterval = .balanced,
        accentColor: WidgetAccentColor = .system
    ) {
        self.id = id
        self.type = type
        self.isEnabled = isEnabled
        self.position = position
        self.displayMode = displayMode
        self.showLabel = showLabel
        self.valueFormat = valueFormat
        self.refreshInterval = refreshInterval
        self.accentColor = accentColor
    }
}

public enum WidgetValueFormat: String, CaseIterable, Identifiable, Codable {
    case percentage = "Percentage"
    case valueWithUnit = "Value with Unit"
    
    public var id: String { rawValue }
}
```

---

## 9. Build and Development

### 9.1 Project Structure

```
Tonic/
├── Tonic.xcodeproj/          # Xcode project
├── Tonic/
│   ├── TonicApp.swift        # App entry point
│   ├── ContentView.swift     # Navigation container
│   ├── Views/                # SwiftUI views
│   │   ├── DashboardView.swift
│   │   ├── SmartScanView.swift
│   │   ├── DeepCleanView.swift
│   │   ├── DiskAnalysisView.swift
│   │   ├── DiskMapView.swift
│   │   ├── SystemStatusDashboard.swift
│   │   ├── AppInventoryView.swift
│   │   ├── WidgetCustomizationView.swift
│   │   ├── OnboardingView.swift
│   │   ├── PreferencesView.swift
│   │   ├── NotificationRulesView.swift
│   │   └── ...
│   ├── Services/             # Business logic
│   │   ├── SmartScanEngine.swift
│   │   ├── DeepCleanEngine.swift
│   │   ├── SystemOptimization.swift
│   │   ├── HiddenSpaceScanner.swift
│   │   ├── CloudStorageScanner.swift
│   │   ├── CollectorBin.swift
│   │   ├── FileOperations.swift
│   │   ├── AppUninstaller.swift
│   │   ├── AppUpdater.swift
│   │   ├── NotificationManager.swift
│   │   ├── WidgetDataManager.swift
│   │   ├── WeatherService.swift
│   │   ├── NotificationRuleEngine.swift
│   │   ├── PermissionManager.swift
│   │   ├── PrivilegedHelperManager.swift
│   │   └── ...
│   ├── Models/               # Data types
│   ├── Design/               # Design system
│   ├── MenuBar/              # Menu bar integration
│   ├── MenuBarWidgets/       # Widget implementations
│   └── Utilities/            # Helpers
│       ├── DiskScanner.swift
│       ├── SparkleUpdater.swift
│       └── TonicColors.swift
├── TonicHelperTool/          # Privileged helper
├── generate_app_icon.swift   # Icon generator
└── create_project.py         # Project setup script
```

### 9.2 Build Commands

```bash
# Generate Xcode project (requires XcodeGen)
xcodegen generate

# Build debug version
xcodebuild -scheme Tonic -configuration Debug build

# Build release version
xcodebuild -scheme Tonic -configuration Release build

# Build with code signing
xcodebuild -scheme Tonic -configuration Release \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGN_STYLE=Automatic \
    build

# Build helper tool
xcodebuild -scheme TonicHelperTool -configuration Release build

# Run tests
xcodebuild -scheme Tonic test
```

### 9.3 Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| Sparkle | 2.x | Software updates |
| SwiftUI | macOS 14+ | UI framework |
| IOKit | System | Hardware access |
| CoreLocation | System | Location services |
| Security | System | Keychain access |

### 9.4 Code Statistics

- **Total Swift Files**: 66
- **Total Lines of Code**: ~30,323
- **Main Directories**: 7 (Views, Services, Models, Design, MenuBar, MenuBarWidgets, Utilities)

---

## Appendix: Quick Reference

### Key Singletons

```swift
WidgetPreferences.shared        // Widget configuration
PermissionManager.shared        // Permission checks
PrivilegedHelperManager.shared  // Root operations
CollectorBin.shared             // Deletion staging
WeatherService.shared           // Weather data
SparkleUpdater.shared           // App updates
```

### Key File Locations

```
~/Library/Application Support/Tonic/  # App data
~/Library/Caches/com.tonic.Tonic/     # Cache
~/Library/Logs/com.tonic.Tonic/       # Logs
/Library/PrivilegedHelperTools/       # Helper binary
```

### Common UserDefaults Keys

```swift
"tonic.widget.hasCompletedOnboarding"
"tonic.themeMode"
"tonic.launchAtLogin"
"hasSeenOnboarding"
```

---

*Last Updated: January 2026*
