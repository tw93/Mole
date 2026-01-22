//
//  SmartScanView.swift
//  Tonic
//
//  Smart Scan feature combining disk analysis, system cleanup check, and app health
//  Task ID: fn-1.17
//

import SwiftUI
import Foundation

// MARK: - Scan Stage

public enum ScanStage: String, CaseIterable, Identifiable {
    case preparing = "Preparing"
    case scanningDisk = "Scanning Disk"
    case checkingApps = "Checking Apps"
    case analyzingSystem = "Analyzing System"
    case complete = "Complete"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .preparing: return "gearshape.2"
        case .scanningDisk: return "externaldrive.fill"
        case .checkingApps: return "app.badge"
        case .analyzingSystem: return "chart.line.uptrend.xyaxis"
        case .complete: return "checkmark.circle.fill"
        }
    }

    var progressWeight: Double {
        switch self {
        case .preparing: return 0.05
        case .scanningDisk: return 0.40
        case .checkingApps: return 0.30
        case .analyzingSystem: return 0.25
        case .complete: return 0.0
        }
    }
}

// MARK: - Scan Recommendation

public struct ScanRecommendation: Identifiable, Hashable, Sendable {
    public let id = UUID()
    let type: RecommendationType
    let title: String
    let description: String
    let actionable: Bool
    let safeToFix: Bool
    let spaceToReclaim: Int64
    let affectedPaths: [String]

    enum RecommendationType: String, CaseIterable {
        case cache = "Cache"
        case logs = "Logs"
        case tempFiles = "Temporary Files"
        case duplicates = "Duplicates"
        case oldApps = "Unused Apps"
        case largeFiles = "Large Files"
        case hiddenSpace = "Hidden Space"
    }

    var formattedSpace: String {
        ByteCountFormatter.string(fromByteCount: spaceToReclaim, countStyle: .file)
    }

    var icon: String {
        switch type {
        case .cache: return "archivebox"
        case .logs: return "doc.text"
        case .tempFiles: return "clock"
        case .duplicates: return "doc.on.doc"
        case .oldApps: return "app.badge"
        case .largeFiles: return "arrow.up.doc"
        case .hiddenSpace: return "eye.slash"
        }
    }

    var color: Color {
        switch type {
        case .cache: return .blue
        case .logs: return .orange
        case .tempFiles: return .purple
        case .duplicates: return .red
        case .oldApps: return .green
        case .largeFiles: return .yellow
        case .hiddenSpace: return .gray
        }
    }
}

// MARK: - Smart Scan Result

public struct SmartScanResult: Sendable {
    let timestamp: Date
    let scanDuration: TimeInterval
    let diskUsage: DiskUsageSummary
    let recommendations: [ScanRecommendation]
    let totalSpaceToReclaim: Int64
    let systemHealthScore: Int // 0-100

    var formattedTotalSpace: String {
        ByteCountFormatter.string(fromByteCount: totalSpaceToReclaim, countStyle: .file)
    }

    var formattedDuration: String {
        String(format: "%.1f seconds", scanDuration)
    }

    var healthScoreColor: Color {
        switch systemHealthScore {
        case 80...100: return TonicColors.success
        case 60..<80: return TonicColors.warning
        default: return TonicColors.error
        }
    }
}

// MARK: - Disk Usage Summary

public struct DiskUsageSummary: Sendable {
    let totalSpace: Int64
    let usedSpace: Int64
    let freeSpace: Int64
    let homeDirectorySize: Int64
    let cacheSize: Int64
    let logSize: Int64
    let tempSize: Int64

    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace) * 100
    }

    var formattedTotalSpace: String {
        ByteCountFormatter.string(fromByteCount: totalSpace, countStyle: .file)
    }

    var formattedUsedSpace: String {
        ByteCountFormatter.string(fromByteCount: usedSpace, countStyle: .file)
    }

    var formattedFreeSpace: String {
        ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file)
    }

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }

    var formattedLogSize: String {
        ByteCountFormatter.string(fromByteCount: logSize, countStyle: .file)
    }

    var formattedTempSize: String {
        ByteCountFormatter.string(fromByteCount: tempSize, countStyle: .file)
    }
}

// MARK: - Smart Scan View

struct SmartScanView: View {
    @State private var scanner = SmartScanEngine()
    @State private var isScanning = false
    @State private var currentStage: ScanStage = .preparing
    @State private var scanProgress: Double = 0
    @State private var scanResult: SmartScanResult?
    @State private var isFixing = false
    @State private var fixProgress: Double = 0
    @State private var selectedRecommendations: Set<UUID> = []
    @State private var showFixCompleteAlert = false
    @State private var fixResult: FixResult?
    @State private var detailRecommendation: ScanRecommendation?
    @State private var showingDetail = false

    private let stages = ScanStage.allCases.filter { $0 != .complete }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Fix Complete", isPresented: $showFixCompleteAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            if let result = fixResult {
                Text(result.message)
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let recommendation = detailRecommendation {
                RecommendationDetailView(
                    recommendation: recommendation,
                    isPresented: $showingDetail
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Smart Scan", systemImage: "sparkles")
                .font(.headline)

            Spacer()

            if isScanning {
                Button("Cancel") {
                    Task { await cancelScan() }
                }
                .buttonStyle(.borderless)
            } else if scanResult != nil {
                Button("Scan Again") {
                    Task { await startScan() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isScanning {
            scanningView
        } else if let result = scanResult {
            resultsView(result)
        } else {
            initialView
        }
    }

    // MARK: - Initial View

    private var initialView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(
                        colors: [TonicColors.accent, TonicColors.pro],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("Smart Scan")
                .font(.title)
                .fontWeight(.semibold)

            Text("Run a comprehensive scan of your disk, apps, and system to find space to reclaim")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            VStack(alignment: .leading, spacing: 12) {
                scanStageItem("Analyze disk usage", icon: "externaldrive.fill")
                scanStageItem("Check app health", icon: "app.badge")
                scanStageItem("Find cache & temp files", icon: "archivebox")
                scanStageItem("Detect hidden space", icon: "eye.slash")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)

            Button("Start Scan") {
                Task { await startScan() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanStageItem(_ text: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(TonicColors.accent)
                .frame(width: 24)

            Text(text)
                .font(.body)

            Spacer()

            Image(systemName: "checkmark")
                .font(.caption)
                .foregroundColor(.secondary)
                .opacity(0)
        }
    }

    // MARK: - Scanning View

    private var scanningView: some View {
        VStack(spacing: 32) {
            Spacer()

            // Progress ring
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 8)
                    .frame(width: 120, height: 120)

                Circle()
                    .trim(from: 0, to: scanProgress)
                    .stroke(
                        LinearGradient(
                            colors: [TonicColors.accent, TonicColors.pro],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: scanProgress)

                VStack(spacing: 4) {
                    Text("\(Int(scanProgress * 100))%")
                        .font(.system(size: 32, weight: .bold, design: .rounded))

                    Text("Complete")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Current stage
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)

                    Text(currentStage.rawValue)
                        .font(.headline)
                }

                Text(getStageDescription(currentStage))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Stage indicators
            HStack(spacing: 16) {
                ForEach(stages) { stage in
                    VStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(stageColor(for: stage))
                                .frame(width: 32, height: 32)

                            Image(systemName: stage.icon)
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .opacity(isStageComplete(stage) || currentStage == stage ? 1 : 0.4)
                        }

                        Text(stage.rawValue)
                            .font(.caption2)
                            .foregroundColor(isStageComplete(stage) || currentStage == stage ? .primary : .secondary)
                    }
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func stageColor(for stage: ScanStage) -> Color {
        if isStageComplete(stage) {
            return TonicColors.success
        } else if currentStage == stage {
            return TonicColors.accent
        } else {
            return Color.gray.opacity(0.3)
        }
    }

    private func isStageComplete(_ stage: ScanStage) -> Bool {
        guard let currentIndex = stages.firstIndex(where: { $0 == currentStage }) else { return false }
        if let stageIndex = stages.firstIndex(where: { $0 == stage }) {
            return stageIndex < currentIndex
        }
        return false
    }

    private func getStageDescription(_ stage: ScanStage) -> String {
        switch stage {
        case .preparing:
            return "Initializing scan components..."
        case .scanningDisk:
            return "Analyzing disk usage and large files..."
        case .checkingApps:
            return "Checking installed applications for updates and unused apps..."
        case .analyzingSystem:
            return "Analyzing system caches, logs, and temporary files..."
        case .complete:
            return "Scan complete!"
        }
    }

    // MARK: - Results View

    private func resultsView(_ result: SmartScanResult) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Summary card
                summaryCard(result)

                // Health score
                healthScoreCard(result)

                // Recommendations
                if !result.recommendations.isEmpty {
                    recommendationsSection(result)
                }

                // Action buttons
                actionButtons(result)
            }
            .padding()
        }
    }

    private func summaryCard(_ result: SmartScanResult) -> some View {
        HStack(spacing: 24) {
            // Space to reclaim
            VStack(alignment: .leading, spacing: 8) {
                Label("Space to Reclaim", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundColor(TonicColors.success)

                Text(result.formattedTotalSpace)
                    .font(.system(size: 36, weight: .bold, design: .rounded))

                Text("can be safely removed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
                .frame(height: 60)

            // Disk usage
            VStack(alignment: .leading, spacing: 8) {
                Label("Disk Usage", systemImage: "externaldrive.fill")
                    .font(.caption)
                    .foregroundColor(TonicColors.accent)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(result.diskUsage.usedPercentage))%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))

                    Text("used")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                ProgressView(value: result.diskUsage.usedPercentage, total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            }

            Spacer()

            // Breakdown
            VStack(alignment: .trailing, spacing: 6) {
                breakdownItem("Cache", result.diskUsage.formattedCacheSize, .blue)
                breakdownItem("Logs", result.diskUsage.formattedLogSize, .orange)
                breakdownItem("Temp", result.diskUsage.formattedTempSize, .purple)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func breakdownItem(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    private func healthScoreCard(_ result: SmartScanResult) -> some View {
        HStack(spacing: 20) {
            // Score ring
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 6)
                    .frame(width: 80, height: 80)

                Circle()
                    .trim(from: 0, to: Double(result.systemHealthScore) / 100)
                    .stroke(result.healthScoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(-90))

                Text("\(result.systemHealthScore)")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(result.healthScoreColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("System Health Score")
                    .font(.headline)

                Text(healthScoreMessage(result.systemHealthScore))
                    .font(.subheadline)
                    .foregroundColor(Color.secondary)

                Text("Scan completed in \(result.formattedDuration)")
                    .font(.caption)
                    .foregroundColor(Color.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }

    private func healthScoreMessage(_ score: Int) -> String {
        switch score {
        case 90...100: return "Excellent! Your system is in great shape."
        case 75..<90: return "Good. Minor optimizations available."
        case 50..<75: return "Fair. Some cleanup recommended."
        default: return "Needs attention. Cleanup recommended."
        }
    }

    private func recommendationsSection(_ result: SmartScanResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recommendations")
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(result.recommendations) { recommendation in
                    RecommendationRow(
                        recommendation: recommendation,
                        isSelected: selectedRecommendations.contains(recommendation.id),
                        toggleSelection: {
                            toggleSelection(recommendation.id)
                        },
                        showDetails: {
                            detailRecommendation = recommendation
                            showingDetail = true
                        }
                    )
                }
            }
        }
    }

    private func actionButtons(_ result: SmartScanResult) -> some View {
        HStack(spacing: 12) {
            if !selectedRecommendations.isEmpty {
                Button("Fix Selected (\(selectedRecommendations.count))") {
                    Task { await fixSelected() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFixing)
            }

            Button("Select Safe Actions") {
                selectSafeActions(from: result.recommendations)
            }
            .buttonStyle(.bordered)
            .disabled(isFixing)

            if !selectedRecommendations.isEmpty {
                Button("Clear Selection") {
                    selectedRecommendations.removeAll()
                }
                .buttonStyle(.bordered)
                .disabled(isFixing)
            }

            Spacer()
        }
    }

    // MARK: - Actions

    private func startScan() async {
        isScanning = true
        scanResult = nil
        selectedRecommendations.removeAll()

        for stage in stages {
            currentStage = stage
            try? await Task.sleep(nanoseconds: 500_000_000) // UI delay

            let progress = await scanner.runStage(stage)
            scanProgress = progress
        }

        currentStage = .complete
        scanProgress = 1.0

        let result = await scanner.finalizeScan()
        scanResult = result

        // Auto-select safe actions
        selectSafeActions(from: result.recommendations)

        isScanning = false
    }

    private func cancelScan() async {
        isScanning = false
        currentStage = .preparing
        scanProgress = 0
    }

    private func toggleSelection(_ id: UUID) {
        if selectedRecommendations.contains(id) {
            selectedRecommendations.remove(id)
        } else {
            selectedRecommendations.insert(id)
        }
    }

    private func selectSafeActions(from recommendations: [ScanRecommendation]) {
        selectedRecommendations = Set(
            recommendations.filter { $0.safeToFix && $0.actionable }
                .map { $0.id }
        )
    }

    private func fixSelected() async {
        guard !selectedRecommendations.isEmpty, let result = scanResult else { return }

        isFixing = true
        let toFix = result.recommendations.filter { selectedRecommendations.contains($0.id) }

        let fixResult = await scanner.fixRecommendations(toFix)
        self.fixResult = fixResult

        isFixing = false
        showFixCompleteAlert = true

        // Refresh scan after fix
        await startScan()
    }
}

// MARK: - Recommendation Row

struct RecommendationRow: View {
    let recommendation: ScanRecommendation
    let isSelected: Bool
    let toggleSelection: () -> Void
    let showDetails: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Selection checkbox
            Button(action: toggleSelection) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? TonicColors.accent : .secondary)
            }
            .buttonStyle(.plain)

            // Icon
            Image(systemName: recommendation.icon)
                .font(.title2)
                .foregroundColor(recommendation.color)
                .frame(width: 32)

            // Content (clickable for details)
            Button(action: showDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(recommendation.title)
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        Spacer()

                        Text(recommendation.formattedSpace)
                            .font(.body)
                            .fontWeight(.semibold)
                            .foregroundColor(recommendation.color)
                    }

                    Text(recommendation.description)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        if recommendation.safeToFix {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.caption2)
                                Text("Safe to remove")
                                    .font(.caption2)
                            }
                            .foregroundColor(TonicColors.success)
                        }

                        // Path count indicator
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.caption2)
                            Text("\(recommendation.affectedPaths.count) locations")
                                .font(.caption2)
                        }
                        .foregroundColor(.secondary)

                        Spacer()

                        // View details hint
                        HStack(spacing: 4) {
                            Text("View details")
                                .font(.caption2)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                        }
                        .foregroundColor(TonicColors.accent)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!recommendation.actionable)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .opacity(recommendation.actionable ? 1 : 0.6)
    }
}

// MARK: - Path Detail Model

struct PathDetail: Identifiable, Hashable, Sendable {
    let id = UUID()
    let path: String
    let size: Int64
    let isDirectory: Bool
    var isExpanded: Bool = false
    var children: [PathDetail]? = nil

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var parentDirectory: String {
        (path as NSString).deletingLastPathComponent
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var displayPath: String {
        if path.hasPrefix(NSHomeDirectory()) {
            return "~" + path.dropFirst(NSHomeDirectory().count)
        }
        return path
    }
}

// MARK: - Recommendation Detail View

struct RecommendationDetailView: View {
    let recommendation: ScanRecommendation
    @Binding var isPresented: Bool
    @State private var pathDetails: [PathDetail] = []
    @State private var selectedItems: Set<String> = []
    @State private var searchText = ""
    @State private var isLoading = true

    @Environment(\.dismiss) private var dismiss

    private var filteredItems: [PathDetail] {
        if searchText.isEmpty {
            return pathDetails
        }
        return pathDetails.filter { detail in
            detail.fileName.localizedCaseInsensitiveContains(searchText) ||
            detail.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var totalSelectedSize: Int64 {
        selectedItems.reduce(0) { total, path in
            total + (pathDetails.first { $0.path == path }?.size ?? 0)
        }
    }

    private var formattedSelectedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSelectedSize, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            // Search and filter bar
            searchBar

            Divider()

            // Content
            if isLoading {
                loadingView
            } else if filteredItems.isEmpty {
                emptyState
            } else {
                itemsList
            }

            Divider()

            // Footer
            footer
        }
        .frame(width: 650, height: 500)
        .onAppear {
            loadPathDetails()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            // Icon
            Image(systemName: recommendation.icon)
                .font(.system(size: 28))
                .foregroundColor(recommendation.color)
                .frame(width: 44)

            // Title info
            VStack(alignment: .leading, spacing: 4) {
                Text(recommendation.title)
                    .font(.headline)

                Text(recommendation.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Safe to fix badge
            if recommendation.safeToFix {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.caption2)
                    Text("Safe to remove")
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(TonicColors.success.opacity(0.15))
                .foregroundColor(TonicColors.success)
                .cornerRadius(6)
            }

            // Close button
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                TextField("Search files and folders...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            Spacer()

            // Selection info
            Text("\(selectedItems.count) selected · \(formattedSelectedSize)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Loading file details...")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("No results found")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(filteredItems) { detail in
                    PathDetailRow(
                        detail: detail,
                        selectedItems: $selectedItems,
                        isTopLevel: true,
                        toggleExpansion: toggleExpansion
                    )

                    if detail.id != filteredItems.last?.id {
                        Divider()
                            .padding(.leading, 60)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            // Select all / Deselect all
            Button(selectedItems.count == filteredItems.count ? "Deselect All" : "Select All") {
                if selectedItems.count == filteredItems.count {
                    selectedItems.removeAll()
                } else {
                    selectedItems = Set(filteredItems.map { $0.path })
                }
            }
            .buttonStyle(.bordered)
            .disabled(filteredItems.isEmpty)

            Spacer()

            // Cancel button
            Button("Cancel") {
                isPresented = false
            }
            .buttonStyle(.bordered)

            // Confirm button
            Button("Apply Selection") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedItems.isEmpty)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func loadPathDetails() {
        isLoading = true

        Task {
            var details: [PathDetail] = []

            for path in recommendation.affectedPaths {
                let detail = await createPathDetail(from: path)
                details.append(detail)
            }

            // Sort by size (descending)
            details.sort { $0.size > $1.size }

            await MainActor.run {
                pathDetails = details
                isLoading = false
            }
        }
    }

    private func createPathDetail(from path: String) async -> PathDetail {
        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default

        fileManager.fileExists(atPath: path, isDirectory: &isDirectory)

        var size: Int64 = 0
        var children: [PathDetail]? = nil

        if isDirectory.boolValue {
            // Get directory size and contents
            if let enumerator = fileManager.enumerator(atPath: path) {
                var childPaths: [String] = []

                // Collect all files first to avoid async context issues
                let allFiles = enumerator.compactMap { $0 as? String }

                for file in allFiles {
                    let fullPath = (path as NSString).appendingPathComponent(file)
                    childPaths.append(fullPath)

                    if let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                       let fileSize = attributes[.size] as? Int64 {
                        size += fileSize
                    }
                }

                // Create child details (limit to first 50 for performance)
                children = Array(childPaths.prefix(50)).map { childPath in
                    PathDetail(
                        path: childPath,
                        size: (try? fileManager.attributesOfItem(atPath: childPath)[.size] as? Int64) ?? 0,
                        isDirectory: (try? fileManager.attributesOfItem(atPath: childPath)[.type] as? FileAttributeType == .typeDirectory) ?? false
                    )
                }
            }
        } else {
            // Single file size
            if let attributes = try? fileManager.attributesOfItem(atPath: path),
               let fileSize = attributes[.size] as? Int64 {
                size = fileSize
            }
        }

        return PathDetail(
            path: path,
            size: size,
            isDirectory: isDirectory.boolValue,
            isExpanded: false,
            children: children
        )
    }

    private func toggleExpansion(_ detail: PathDetail) {
        if let index = pathDetails.firstIndex(where: { $0.id == detail.id }) {
            pathDetails[index].isExpanded.toggle()
        }
    }
}

// MARK: - Path Detail Row

struct PathDetailRow: View {
    let detail: PathDetail
    @Binding var selectedItems: Set<String>
    let isTopLevel: Bool
    let toggleExpansion: (PathDetail) -> Void

    private var isSelected: Bool {
        selectedItems.contains(detail.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Selection checkbox
                Button {
                    toggleSelection()
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? TonicColors.accent : .secondary)
                }
                .buttonStyle(.plain)

                // Expand/collapse for directories
                if detail.isDirectory && (detail.children?.isEmpty == false) {
                    Button {
                        toggleExpansion(detail)
                    } label: {
                        Image(systemName: detail.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 16)
                }

                // Icon
                Image(systemName: detail.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 16))
                    .foregroundColor(detail.isDirectory ? .blue : .secondary)
                    .frame(width: 20)

                // Name and size
                VStack(alignment: .leading, spacing: 2) {
                    Text(detail.fileName)
                        .font(.body)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(detail.formattedSize)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if !isTopLevel {
                            Text("·")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(detail.parentDirectory)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Show in Finder button
                Button {
                    showInFinder()
                } label: {
                    Image(systemName: "arrow.right.square")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )

            // Expanded children
            if detail.isExpanded, let children = detail.children, !children.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        PathDetailRow(
                            detail: child,
                            selectedItems: $selectedItems,
                            isTopLevel: false,
                            toggleExpansion: toggleExpansion
                        )
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private func toggleSelection() {
        if selectedItems.contains(detail.path) {
            selectedItems.remove(detail.path)
        } else {
            selectedItems.insert(detail.path)
        }
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private var path: String {
        detail.path
    }
}

// MARK: - Fix Result

struct FixResult {
    let itemsFixed: Int
    let spaceFreed: Int64
    let errors: Int

    var message: String {
        let spaceStr = ByteCountFormatter.string(fromByteCount: spaceFreed, countStyle: .file)
        if errors > 0 {
            return "Fixed \(itemsFixed) items, freed \(spaceStr). \(errors) items had errors."
        }
        return "Successfully fixed \(itemsFixed) items and freed \(spaceStr)!"
    }
}

// MARK: - Preview

#Preview {
    SmartScanView()
        .frame(width: 700, height: 500)
}
