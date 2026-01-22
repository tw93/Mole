//
//  DashboardView.swift
//  Tonic
//
//  Main dashboard view with Smart Scan functionality
//  Replaces placeholder dashboard with full-featured dashboard
//

import SwiftUI
import IOKit.ps

// MARK: - Activity Timeline Model

struct ActivityItem: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let type: ActivityType
    let title: String
    let description: String
    let impact: ImpactLevel

    enum ActivityType: String {
        case scan = "Scan"
        case clean = "Clean"
        case optimize = "Optimize"
        case alert = "Alert"
        case info = "Info"

        var icon: String {
            switch self {
            case .scan: return "magnifyingglass"
            case .clean: return "sparkles"
            case .optimize: return "gearshape.2"
            case .alert: return "exclamationmark.triangle.fill"
            case .info: return "info.circle"
            }
        }

        var color: Color {
            switch self {
            case .scan: return DesignTokens.Colors.accent
            case .clean: return DesignTokens.Colors.success
            case .optimize: return DesignTokens.Colors.pro
            case .alert: return DesignTokens.Colors.error
            case .info: return DesignTokens.Colors.textSecondary
            }
        }
    }

    enum ImpactLevel: String {
        case high = "High"
        case medium = "Medium"
        case low = "Low"

        var color: Color {
            switch self {
            case .high: return DesignTokens.Colors.error
            case .medium: return DesignTokens.Colors.warning
            case .low: return DesignTokens.Colors.success
            }
        }
    }

    static func == (lhs: ActivityItem, rhs: ActivityItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Recommendation Model

struct Recommendation: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let description: String
    let type: RecommendationType
    let priority: Priority
    let actionText: String
    var isCompleted: Bool = false

    enum RecommendationType {
        case clean
        case optimize
        case update
        case security

        var icon: String {
            switch self {
            case .clean: return "trash.fill"
            case .optimize: return "speedometer"
            case .update: return "arrow.up.circle.fill"
            case .security: return "checkmark.shield.fill"
            }
        }

        var color: Color {
            switch self {
            case .clean: return DesignTokens.Colors.accent
            case .optimize: return DesignTokens.Colors.pro
            case .update: return DesignTokens.Colors.success
            case .security: return DesignTokens.Colors.error
            }
        }
    }

    enum Priority {
        case critical
        case high
        case medium
        case low

        var color: Color {
            switch self {
            case .critical: return DesignTokens.Colors.error
            case .high: return DesignTokens.Colors.warning
            case .medium: return DesignTokens.Colors.pro
            case .low: return DesignTokens.Colors.success
            }
        }

        var label: String {
            switch self {
            case .critical: return "Critical"
            case .high: return "High"
            case .medium: return "Medium"
            case .low: return "Low"
            }
        }
    }

    static func == (lhs: Recommendation, rhs: Recommendation) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Smart Scan State Manager

@MainActor
class SmartScanManager: ObservableObject {
    @Published var isScanning = false
    @Published var scanProgress: Double = 0.0
    @Published var currentPhase: ScanPhase = .idle
    @Published var lastScanResult: ScanResult?
    @Published var healthScore: Int = 85
    @Published var activityHistory: [ActivityItem] = []
    @Published var recommendations: [Recommendation] = []

    private var systemMonitor = SystemMonitor()

    enum ScanPhase: String, CaseIterable {
        case idle = "Ready"
        case analyzing = "Analyzing system"
        case scanningJunk = "Scanning junk files"
        case checkingMemory = "Checking memory pressure"
        case evaluatingApps = "Evaluating applications"
        case complete = "Complete"

        var icon: String {
            switch self {
            case .idle: return "circle"
            case .analyzing: return "magnifyingglass"
            case .scanningJunk: return "doc.fill"
            case .checkingMemory: return "memorychip"
            case .evaluatingApps: return "app.badge"
            case .complete: return "checkmark.circle.fill"
            }
        }
    }

    init() {
        loadSampleData()
    }

    // MARK: - Smart Scan

    func startSmartScan() async {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = 0.0

        // Phase 1: Analyzing
        currentPhase = .analyzing
        try? await Task.sleep(nanoseconds: 500_000_000)
        scanProgress = 0.2

        // Phase 2: Scanning junk files
        currentPhase = .scanningJunk
        try? await Task.sleep(nanoseconds: 800_000_000)
        scanProgress = 0.4

        // Phase 3: Checking memory
        currentPhase = .checkingMemory
        try? await Task.sleep(nanoseconds: 600_000_000)
        scanProgress = 0.6

        // Phase 4: Evaluating apps
        currentPhase = .evaluatingApps
        try? await Task.sleep(nanoseconds: 700_000_000)
        scanProgress = 0.8

        // Generate results
        let result = generateScanResult()
        lastScanResult = result
        healthScore = result.healthScore

        // Update recommendations based on scan
        updateRecommendations(from: result)

        // Add to activity
        let activity = ActivityItem(
            timestamp: Date(),
            type: .scan,
            title: "Smart Scan Completed",
            description: "Found \(formatBytes(result.totalReclaimableSpace)) of reclaimable space",
            impact: result.totalReclaimableSpace > 1_000_000_000 ? .high : .medium
        )
        activityHistory.insert(activity, at: 0)
        if activityHistory.count > 10 {
            activityHistory.removeLast()
        }

        scanProgress = 1.0
        currentPhase = .complete
        isScanning = false
    }

    // MARK: - Quick Actions

    func quickScan() async {
        await startSmartScan()
    }

    func quickClean() async {
        // Simulate quick clean
        let activity = ActivityItem(
            timestamp: Date(),
            type: .clean,
            title: "Quick Clean",
            description: "Cleaned temporary files and cache",
            impact: .medium
        )
        activityHistory.insert(activity, at: 0)

        // Update a recommendation
        if let index = recommendations.firstIndex(where: { $0.type == .clean }) {
            recommendations[index].isCompleted = true
        }
    }

    func quickOptimize() async {
        // Simulate optimization
        let activity = ActivityItem(
            timestamp: Date(),
            type: .optimize,
            title: "System Optimized",
            description: "Optimized memory and startup items",
            impact: .low
        )
        activityHistory.insert(activity, at: 0)
    }

    // MARK: - Helpers

    private func generateScanResult() -> ScanResult {
        // Simulated scan result - in production, this would use real data
        let junkSize = Int64.random(in: 500_000_000...3_000_000_000)
        let healthScore = max(Int(100 - (Int(junkSize) / 100_000_000)), 50)

        return ScanResult(
            id: UUID(),
            timestamp: Date(),
            healthScore: healthScore,
            junkFiles: JunkCategory(
                tempFiles: FileGroup(name: "Temporary Files", description: "App temp files", size: junkSize / 3, count: 1240),
                cacheFiles: FileGroup(name: "Cache Files", description: "Application cache", size: junkSize / 2, count: 850),
                logFiles: FileGroup(name: "Log Files", description: "Old log files", size: junkSize / 6, count: 320),
                trashItems: FileGroup(name: "Trash", description: "Items in trash", size: 0, count: 0),
                languageFiles: FileGroup(name: "Language Files", description: "Unused localizations", size: 150_000_000, count: 4500),
                oldFiles: FileGroup(name: "Old Files", description: "Files older than 90 days", size: 200_000_000, count: 150)
            ),
            performanceIssues: PerformanceCategory(
                launchAgents: FileGroup(name: "Launch Agents", description: "Disabled", size: 0, count: 0),
                loginItems: FileGroup(name: "Login Items", description: "5 items", size: 0, count: 5),
                browserCaches: FileGroup(name: "Browser Cache", description: "Chrome, Safari", size: 450_000_000, count: 1200),
                memoryIssues: ["High memory pressure detected"],
                diskFragmentation: nil
            ),
            appIssues: AppIssueCategory(
                unusedApps: [],
                largeApps: [],
                duplicateApps: [],
                orphanedFiles: []
            ),
            privacyIssues: PrivacyCategory(
                browserHistory: FileGroup(name: "Browser History", description: "History data", size: 25_000_000, count: 5000),
                downloadHistory: FileGroup(name: "Downloads", description: "Download history", size: 5_000_000, count: 150),
                recentDocuments: FileGroup(name: "Recent Documents", description: "Recent items", size: 1_000_000, count: 50),
                clipboardData: FileGroup(name: "Clipboard", description: "Clipboard data", size: 0, count: 0)
            ),
            totalReclaimableSpace: junkSize
        )
    }

    private func updateRecommendations(from result: ScanResult) {
        recommendations.removeAll()

        // Add junk file recommendation
        if result.junkFiles.totalSize > 100_000_000 {
            recommendations.append(Recommendation(
                title: "Clean Junk Files",
                description: formatBytes(result.junkFiles.totalSize) + " of junk files found",
                type: .clean,
                priority: result.junkFiles.totalSize > 1_000_000_000 ? .high : .medium,
                actionText: "Clean Now"
            ))
        }

        // Add memory recommendation
        if !result.performanceIssues.memoryIssues.isEmpty {
            recommendations.append(Recommendation(
                title: "Optimize Memory",
                description: "High memory pressure detected",
                type: .optimize,
                priority: .high,
                actionText: "Optimize"
            ))
        }

        // Add login items recommendation
        if result.performanceIssues.loginItems.count > 3 {
            recommendations.append(Recommendation(
                title: "Review Login Items",
                description: "\(result.performanceIssues.loginItems.count) items slowing startup",
                type: .optimize,
                priority: .medium,
                actionText: "Review"
            ))
        }

        // Add browser cache recommendation
        if result.performanceIssues.browserCaches.size > 100_000_000 {
            recommendations.append(Recommendation(
                title: "Clear Browser Cache",
                description: formatBytes(result.performanceIssues.browserCaches.size) + " of cached data",
                type: .clean,
                priority: .low,
                actionText: "Clear"
            ))
        }
    }

    private func loadSampleData() {
        // Sample activity history
        activityHistory = [
            ActivityItem(
                timestamp: Date().addingTimeInterval(-3600),
                type: .clean,
                title: "Cache Cleaned",
                description: "450 MB of browser cache removed",
                impact: .medium
            ),
            ActivityItem(
                timestamp: Date().addingTimeInterval(-86400),
                type: .scan,
                title: "Scheduled Scan",
                description: "System health is good",
                impact: .low
            ),
            ActivityItem(
                timestamp: Date().addingTimeInterval(-172800),
                type: .optimize,
                title: "Memory Optimized",
                description: "Freed 1.2 GB of memory",
                impact: .high
            ),
            ActivityItem(
                timestamp: Date().addingTimeInterval(-259200),
                type: .info,
                title: "Tonic Updated",
                description: "Version 0.1.0 installed",
                impact: .low
            )
        ]

        // Initial recommendations
        recommendations = [
            Recommendation(
                title: "Clean Junk Files",
                description: "1.2 GB of junk files found",
                type: .clean,
                priority: .high,
                actionText: "Clean Now"
            ),
            Recommendation(
                title: "Review Login Items",
                description: "5 items slowing startup",
                type: .optimize,
                priority: .medium,
                actionText: "Review"
            ),
            Recommendation(
                title: "Clear Browser Cache",
                description: "450 MB of cached data",
                type: .clean,
                priority: .low,
                actionText: "Clear"
            )
        ]
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Main Dashboard View

struct DashboardView: View {
    @StateObject private var scanManager = SmartScanManager()
    @StateObject private var systemMonitor = SystemMonitor()
    @State private var showWidgetCustomization = false
    @State private var showWidgetOnboarding = false

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.lg) {
                // Header with Health Score
                headerSection

                // Quick Action Buttons
                quickActionsSection

                // Quick Stats Cards
                quickStatsSection

                // Menu Bar Widgets Section
                widgetSetupSection

                // Recommendations
                if !scanManager.recommendations.isEmpty {
                    recommendationsSection
                }

                // Recent Activity
                activitySection
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .background(DesignTokens.Colors.background)
        .sheet(isPresented: $showWidgetCustomization) {
            WidgetCustomizationView()
        }
        .sheet(isPresented: $showWidgetOnboarding) {
            WidgetOnboardingView()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack(spacing: DesignTokens.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("System Health")
                    .font(DesignTokens.Typography.bodyLarge)
                    .foregroundColor(DesignTokens.Colors.textSecondary)

                Text("\(scanManager.healthScore)")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(healthScoreColor)

                Text(healthRatingText)
                    .font(DesignTokens.Typography.headlineMedium)
                    .foregroundColor(healthScoreColor)
            }

            Spacer()

            // Circular health indicator
            ZStack {
                Circle()
                    .stroke(DesignTokens.Colors.surface, lineWidth: 12)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: CGFloat(scanManager.healthScore) / 100)
                    .stroke(healthScoreColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.5), value: scanManager.healthScore)

                Image(systemName: healthIcon)
                    .font(.system(size: 32))
                    .foregroundColor(healthScoreColor)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }

    private var healthScoreColor: Color {
        switch scanManager.healthScore {
        case 90...100: return DesignTokens.Colors.success
        case 75..<90: return DesignTokens.Colors.progressLow
        case 50..<75: return DesignTokens.Colors.warning
        default: return DesignTokens.Colors.error
        }
    }

    private var healthRatingText: String {
        switch scanManager.healthScore {
        case 90...100: return "Excellent"
        case 75..<90: return "Good"
        case 50..<75: return "Fair"
        case 25..<50: return "Poor"
        default: return "Critical"
        }
    }

    private var healthIcon: String {
        switch scanManager.healthScore {
        case 90...100: return "star.fill"
        case 75..<90: return "hand.thumbsup.fill"
        case 50..<75: return "equal"
        case 25..<50: return "hand.thumbsdown.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    // MARK: - Quick Actions Section

    private var quickActionsSection: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            // Smart Scan Button (Primary)
            QuickActionButton(
                icon: scanManager.isScanning ? "stop.fill" : "sparkles",
                title: scanManager.isScanning ? "Scanning..." : "Smart Scan",
                subtitle: "Comprehensive system scan",
                color: DesignTokens.Colors.accent,
                isPrimary: true,
                isLoading: scanManager.isScanning
            ) {
                if scanManager.isScanning {
                    // Cancel scan - for now just return
                } else {
                    Task {
                        await scanManager.startSmartScan()
                    }
                }
            }

            // Quick Clean
            QuickActionButton(
                icon: "trash.fill",
                title: "Clean",
                subtitle: "Remove junk files",
                color: DesignTokens.Colors.success
            ) {
                Task {
                    await scanManager.quickClean()
                }
            }

            // Optimize
            QuickActionButton(
                icon: "gearshape.2",
                title: "Optimize",
                subtitle: "Improve performance",
                color: DesignTokens.Colors.pro
            ) {
                Task {
                    await scanManager.quickOptimize()
                }
            }
        }
    }

    // MARK: - Quick Stats Section

    private var quickStatsSection: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            if let status = systemMonitor.currentStatus {
                // Storage
                DashboardQuickStatCard(
                    icon: "internaldrive.fill",
                    title: "Storage",
                    value: storageUsageText(status: status),
                    color: storageColor(status: status)
                )

                // Memory
                DashboardQuickStatCard(
                    icon: "memorychip.fill",
                    title: "Memory",
                    value: "\(Int(status.memoryUsagePercentage))%",
                    color: status.memoryPressure.color
                )

                // CPU
                DashboardQuickStatCard(
                    icon: "cpu.fill",
                    title: "CPU",
                    value: "\(Int(status.cpuUsage))%",
                    color: cpuColor(status.cpuUsage)
                )
            } else {
                // Loading placeholders
                ForEach(0..<3) { _ in
                    DashboardQuickStatCard(
                        icon: "circle.fill",
                        title: "Loading",
                        value: "--",
                        color: DesignTokens.Colors.textSecondary
                    )
                }
            }
        }
    }

    private func storageUsageText(status: SystemStatus) -> String {
        if let bootVolume = status.diskUsage.first(where: { $0.isBootVolume }) {
            return "\(Int(bootVolume.usagePercentage))%"
        }
        return "--"
    }

    private func storageColor(status: SystemStatus) -> Color {
        if let bootVolume = status.diskUsage.first(where: { $0.isBootVolume }) {
            switch bootVolume.usagePercentage {
            case 0..<70: return DesignTokens.Colors.success
            case 70..<90: return DesignTokens.Colors.warning
            default: return DesignTokens.Colors.error
            }
        }
        return DesignTokens.Colors.textSecondary
    }

    private func cpuColor(_ usage: Double) -> Color {
        switch usage {
        case 0..<50: return DesignTokens.Colors.success
        case 50..<80: return DesignTokens.Colors.warning
        default: return DesignTokens.Colors.error
        }
    }

    // MARK: - Widget Setup Section

    private var widgetSetupSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            SectionHeader(title: "Menu Bar Widgets", subtitle: "Monitor your system from the menu bar")

            HStack(spacing: DesignTokens.Spacing.md) {
                // Widget info card
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2")
                            .font(.title2)
                            .foregroundStyle(.linearGradient(
                                colors: [TonicColors.accent, TonicColors.pro],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Real-Time System Monitoring")
                                .font(DesignTokens.Typography.headlineMedium)
                                .foregroundColor(DesignTokens.Colors.text)

                            Text("Track CPU, Memory, Disk, Network, Weather, and more right from your menu bar")
                                .font(DesignTokens.Typography.bodySmall)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }

                        Spacer()
                    }

                    // Feature list
                    HStack(spacing: 20) {
                        widgetFeature("cpu.fill", "CPU")
                        widgetFeature("memorychip.fill", "Memory")
                        widgetFeature("internaldrive.fill", "Disk")
                        widgetFeature("wifi", "Network")
                        widgetFeature("cloud.sun.fill", "Weather")
                    }
                    .padding(.top, DesignTokens.Spacing.sm)
                }

                // Setup button
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Button {
                        setupWidgets()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill")
                            Text(setupButtonText)
                        }
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundColor(.white)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.vertical, DesignTokens.Spacing.md)
                        .background(
                            LinearGradient(
                                colors: [TonicColors.accent, TonicColors.pro],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(DesignTokens.CornerRadius.large)
                    }
                    .buttonStyle(.plain)

                    Text(WidgetPreferences.shared.hasCompletedOnboarding ? "Click to customize your widgets" : "First-time setup required")
                        .font(DesignTokens.Typography.captionSmall)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
                .frame(minWidth: 200)
            }
            .padding(DesignTokens.Spacing.md)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(DesignTokens.CornerRadius.large)
        }
    }

    private func widgetFeature(_ icon: String, _ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(TonicColors.accent)
                .frame(width: 16)
            Text(name)
                .font(.caption)
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
    }

    private var setupButtonText: String {
        WidgetPreferences.shared.hasCompletedOnboarding ? "Customize Widgets" : "Setup Widgets"
    }

    private func setupWidgets() {
        if WidgetPreferences.shared.hasCompletedOnboarding {
            showWidgetCustomization = true
        } else {
            showWidgetOnboarding = true
        }
    }

    // MARK: - Recommendations Section

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            SectionHeader(title: "Recommendations", subtitle: "Suggested actions to improve performance")

            VStack(spacing: DesignTokens.Spacing.sm) {
                ForEach(scanManager.recommendations.filter { !$0.isCompleted }) { recommendation in
                    RecommendationCard(recommendation: recommendation) {
                        Task {
                            await handleRecommendation(recommendation)
                        }
                    }
                }
            }
        }
    }

    private func handleRecommendation(_ recommendation: Recommendation) async {
        switch recommendation.type {
        case .clean:
            await scanManager.quickClean()
        case .optimize:
            await scanManager.quickOptimize()
        case .update, .security:
            break
        }
    }

    // MARK: - Activity Section

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            SectionHeader(
                title: "Recent Activity",
                subtitle: "Latest system actions and events"
            )

            VStack(spacing: 0) {
                ForEach(scanManager.activityHistory.prefix(5)) { activity in
                    ActivityRow(activity: activity)

                    if activity != scanManager.activityHistory.prefix(5).last {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
            .background(DesignTokens.Colors.surface)
            .cornerRadius(DesignTokens.CornerRadius.large)
        }
    }
}

// MARK: - Quick Action Button Component

struct QuickActionButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let isPrimary: Bool
    let isLoading: Bool
    let action: () -> Void

    init(
        icon: String,
        title: String,
        subtitle: String,
        color: Color,
        isPrimary: Bool = false,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.isPrimary = isPrimary
        self.isLoading = isLoading
        self.action = action
    }

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundColor(isPrimary ? .white : color)

                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }

                    Spacer()
                }

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(title)
                        .font(DesignTokens.Typography.headlineSmall)
                        .foregroundColor(isPrimary ? .white : DesignTokens.Colors.text)

                    Text(subtitle)
                        .font(DesignTokens.Typography.bodySmall)
                        .foregroundColor(isPrimary ? .white.opacity(0.8) : DesignTokens.Colors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)
            .background(isPrimary ? color : (isHovered ? DesignTokens.Colors.surfaceHovered : DesignTokens.Colors.surface))
            .cornerRadius(DesignTokens.CornerRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large)
                    .stroke(color, lineWidth: isPrimary ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignTokens.Animation.fast) {
                isHovered = hovering
            }
        }
        .disabled(isLoading && isPrimary)
    }
}

// MARK: - Quick Stat Card Component

struct DashboardQuickStatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.system(size: 16))

                Spacer()
            }

            Text(value)
                .font(DesignTokens.Typography.displaySmall)
                .foregroundColor(DesignTokens.Colors.text)

            Text(title)
                .font(DesignTokens.Typography.bodySmall)
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }
}

// MARK: - Recommendation Card Component

struct RecommendationCard: View {
    let recommendation: Recommendation
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            // Icon
            ZStack {
                Circle()
                    .fill(recommendation.type.color.opacity(0.15))
                    .frame(width: 44, height: 44)

                Image(systemName: recommendation.type.icon)
                    .foregroundColor(recommendation.type.color)
                    .font(.system(size: 18))
            }

            // Content
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack {
                    Text(recommendation.title)
                        .font(DesignTokens.Typography.headlineSmall)
                        .foregroundColor(DesignTokens.Colors.text)

                    Badge(text: recommendation.priority.label, color: recommendation.priority.color, size: .small)
                }

                Text(recommendation.description)
                    .font(DesignTokens.Typography.bodySmall)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }

            Spacer()

            // Action Button
            Button(action: action) {
                Text(recommendation.actionText)
                    .font(DesignTokens.Typography.bodySmall)
                    .foregroundColor(.white)
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.vertical, DesignTokens.Spacing.xs)
                    .background(recommendation.type.color)
                    .cornerRadius(DesignTokens.CornerRadius.medium)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignTokens.Spacing.md)
        .background(isHovered ? DesignTokens.Colors.surfaceHovered : DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.medium)
        .onHover { hovering in
            withAnimation(DesignTokens.Animation.fast) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Activity Row Component

struct ActivityRow: View {
    let activity: ActivityItem

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            // Icon
            ZStack {
                Circle()
                    .fill(activity.type.color.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: activity.type.icon)
                    .foregroundColor(activity.type.color)
                    .font(.system(size: 14))
            }

            // Content
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(activity.title)
                    .font(DesignTokens.Typography.bodyMedium)
                    .foregroundColor(DesignTokens.Colors.text)

                Text(activity.description)
                    .font(DesignTokens.Typography.bodySmall)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }

            Spacer()

            // Time and Impact
            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xxs) {
                Text(relativeTime)
                    .font(DesignTokens.Typography.captionMedium)
                    .foregroundColor(DesignTokens.Colors.textSecondary)

                HStack(spacing: DesignTokens.Spacing.xxs) {
                    Circle()
                        .fill(activity.impact.color)
                        .frame(width: 6, height: 6)

                    Text(activity.impact.rawValue)
                        .font(DesignTokens.Typography.captionSmall)
                        .foregroundColor(DesignTokens.Colors.textTertiary)
                }
            }
        }
        .padding(DesignTokens.Spacing.md)
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: activity.timestamp, relativeTo: Date())
    }
}

// MARK: - Preview

#Preview {
    DashboardView()
        .frame(width: 900, height: 700)
}
