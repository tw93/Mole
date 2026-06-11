import SwiftUI
import AppKit

@MainActor
public struct RoomyRootView: View {
    @StateObject private var model: RoomyViewModel

    public init() {
        _model = StateObject(wrappedValue: RoomyViewModel())
    }

    public init(model: RoomyViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        NavigationSplitView {
            List(RoomySection.allCases, selection: $model.selectedSection) { section in
                Label(section.rawValue, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            ZStack(alignment: .top) {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        if let error = model.error(for: model.selectedSection) {
                            NoticeView(text: error, symbol: "exclamationmark.triangle", tint: .orange)
                        }
                        selectedContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .task {
            await model.loadHome()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedSection.rawValue)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(model.loadingSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                Task { await refreshSelectedSection() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(model.isLoading)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch model.selectedSection {
        case .home:
            HomeView(model: model)
        case .cleanup:
            CleanupView(model: model)
        case .applications:
            ApplicationsView(model: model)
        case .storage:
            StorageView(model: model)
        case .performance:
            PerformanceView(model: model)
        case .monitor:
            MonitorView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }

    private var subtitle: String {
        switch model.selectedSection {
        case .home: "Free up disk space with previews, storage scans, and recoverable cleanup"
        case .cleanup: "Preview cleanup, review the plan, then choose what moves to Trash"
        case .applications: "Installed apps and uninstall metadata"
        case .storage: "Disk overview, large files, and cleanable folders"
        case .performance: "Safe maintenance tasks and admin requirements"
        case .monitor: "Live CPU, memory, disk, battery, network, and process signals"
        case .settings: "Permissions, CLI path, whitelists, logs, and execution behavior"
        }
    }

    private func refreshSelectedSection() async {
        switch model.selectedSection {
        case .home:
            await model.loadHome()
        case .cleanup:
            await model.loadCleanupPreview()
        case .applications:
            await model.loadApplications()
        case .storage:
            await model.loadStorage()
            await model.loadPurgePreview()
            await model.loadInstallerPreview()
        case .performance:
            await model.loadOptimizePreview()
        case .monitor:
            await model.loadStatus()
        case .settings:
            await model.loadSettings()
        }
    }
}

private struct AppBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
        .ignoresSafeArea()
    }
}

private struct HomeView: View {
    @ObservedObject var model: RoomyViewModel
    @State private var showCleanupConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                MetricCard(
                    title: "Free Space",
                    value: Formatters.bytes(freeDiskBytes),
                    detail: primaryDisk?.mount ?? "Root volume",
                    tint: model.diskPressure > 85 ? .orange : .green,
                    symbol: "internaldrive"
                )
                MetricCard(
                    title: "Disk Used",
                    value: Formatters.percent(model.diskPressure),
                    detail: diskUsageDetail,
                    tint: model.diskPressure > 85 ? .orange : .blue,
                    symbol: "chart.pie"
                )
                MetricCard(
                    title: "Potential Cleanup",
                    value: cleanupMetricValue,
                    detail: cleanupMetricDetail,
                    tint: .green,
                    symbol: "sparkles"
                )
            }

            if model.fullDiskAccessStatus.state != .enabled && !model.permissionOnboardingDismissed {
                PermissionOnboardingCard(model: model)
            }

            CleanupFlowPanel(
                preview: model.cleanupPreview,
                executionState: model.executionState,
                isLoading: model.isLoading,
                onPreview: startCleanupFlow,
                onReview: {
                    model.selectedSection = .cleanup
                    Task { await model.loadCleanupPreview() }
                }
            )

            RecoveryReportPanel(
                entries: model.operationJournalEntries,
                logPath: model.logPath,
                isLoading: model.isLoading,
                onRefresh: {
                    model.loadOperationJournal(limit: 24)
                }
            )

            ExecutionEventsView(events: model.executionEvents, state: model.executionState)

            SectionBand(title: "Recent Activity", symbol: "clock.arrow.circlepath") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Operation journal")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            model.loadOperationJournal()
                        } label: {
                            Label("Refresh Activity", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isLoading)
                    }

                    if model.operationJournalEntries.isEmpty {
                        EmptyStateView(
                            title: "No activity loaded",
                            detail: "Recent previews, cleanup runs, skipped paths, and Trash operations appear here.",
                            symbol: "clock.arrow.circlepath"
                        )
                    } else {
                        DataTable {
                            ForEach(model.operationJournalEntries.prefix(8)) { entry in
                                OperationJournalRow(entry: entry)
                            }
                            HiddenCountLine(
                                total: model.operationJournalEntries.count,
                                visibleLimit: 8,
                                noun: "journal entries"
                            )
                        }
                    }
                }
            }

            SectionBand(title: "Secondary Cleanup Tools", symbol: "square.grid.2x2") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    Button {
                        Task {
                            model.selectedSection = .cleanup
                            await model.loadCleanupPreview()
                        }
                    } label: {
                        ActionRow(
                            title: "Review cleanup",
                            detail: "Category preview, risk, whitelist, and admin needs.",
                            symbol: "doc.text.magnifyingglass",
                            tint: .green
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoading)

                    Button {
                        Task {
                            model.selectedSection = .storage
                            await model.loadStorage()
                        }
                    } label: {
                        ActionRow(
                            title: "Scan storage",
                            detail: "Largest folders, files, and duplicate candidates.",
                            symbol: "internaldrive",
                            tint: .blue
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoading)

                    Button {
                        Task {
                            model.selectedSection = .storage
                            await model.loadInstallerPreview()
                        }
                    } label: {
                        ActionRow(
                            title: "Find installers",
                            detail: "Redundant DMG, PKG, ZIP, ISO, and XIP files.",
                            symbol: "shippingbox",
                            tint: .orange
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoading)

                    Button {
                        Task {
                            model.selectedSection = .storage
                            await model.loadPurgePreview()
                        }
                    } label: {
                        ActionRow(
                            title: "Project artifacts",
                            detail: "Old node_modules, build, dist, Pods, and .build folders.",
                            symbol: "hammer",
                            tint: .purple
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoading)
                }
            }
        }
        .confirmationDialog("Move recoverable files to Trash?", isPresented: $showCleanupConfirm) {
            if !model.isLoading, model.cleanupPreview != nil {
                Button("Move Recoverable Files to Trash", role: .destructive) {
                    guard !model.isLoading else { return }
                    Task { await model.executeCleanupFlow() }
                }
            }
            Button("Review Plan") {
                model.selectedSection = .cleanup
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanupConfirmationMessage)
        }
    }

    private var primaryDisk: DiskStatus? {
        model.status?.disks.first(where: { $0.mount == "/" }) ?? model.status?.disks.first
    }

    private var freeDiskBytes: UInt64 {
        guard let primaryDisk, primaryDisk.total >= primaryDisk.used else { return 0 }
        return primaryDisk.total - primaryDisk.used
    }

    private var diskUsageDetail: String {
        guard let primaryDisk else { return "Load storage status" }
        return "\(Formatters.bytes(primaryDisk.used)) of \(Formatters.bytes(primaryDisk.total)) used"
    }

    private var cleanupMetricValue: String {
        guard let preview = model.cleanupPreview else { return "Not scanned" }
        return Formatters.bytes(preview.estimatedBytes)
    }

    private var cleanupMetricDetail: String {
        guard let preview = model.cleanupPreview else { return "Run cleanup preview" }
        return "\(preview.itemCount) items"
    }

    private var cleanupConfirmationMessage: String {
        cleanupConfirmationCopy(for: model.cleanupPreview)
    }

    private func startCleanupFlow() {
        if model.cleanupPreview != nil, model.executionState == .previewReady {
            showCleanupConfirm = true
            return
        }
        Task {
            await model.prepareCleanupFlow()
            if model.cleanupPreview != nil, model.error(for: .home) == nil {
                showCleanupConfirm = true
            }
        }
    }
}

private struct CleanupView: View {
    @ObservedObject var model: RoomyViewModel
    @State private var showCleanupConfirm = false
    @State private var externalPath = "/Volumes/"
    @State private var previewedExternalPath = ""
    @State private var showExternalConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                MetricCard(
                    title: "Previewed Space",
                    value: cleanupMetricValue,
                    detail: cleanupMetricDetail,
                    tint: .green,
                    symbol: "sparkles"
                )
                MetricCard(
                    title: "Protected",
                    value: protectedMetricValue,
                    detail: protectedMetricDetail,
                    tint: .blue,
                    symbol: "shield"
                )
                MetricCard(
                    title: "Admin",
                    value: adminMetricValue,
                    detail: adminMetricDetail,
                    tint: model.cleanupPreview?.adminRequired == true ? .orange : .green,
                    symbol: "lock"
                )
            }

            CleanupFlowPanel(
                preview: model.cleanupPreview,
                executionState: model.executionState,
                isLoading: model.isLoading,
                onPreview: startCleanupFlow,
                onReview: {
                    Task { await model.loadCleanupPreview() }
                }
            )

            SectionBand(title: "Cleanup Categories", symbol: "list.bullet.rectangle") {
                if let preview = model.cleanupPreview, !preview.categories.isEmpty {
                    DataTable {
                        ForEach(preview.categories) { item in
                            CleanupCategoryRow(item: item)
                        }
                    }
                } else {
                    EmptyStateView(
                        title: "No cleanup preview loaded",
                        detail: "Run Preview to ask Roomy for a fresh dry run.",
                        symbol: "doc.text.magnifyingglass"
                    )
                }
            }

            SectionBand(title: "External Volume Cleanup", symbol: "externaldrive") {
                HStack {
                    TextField("Mounted volume path", text: $externalPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                    Button {
                        chooseExternalVolume()
                    } label: {
                        Label("Choose", systemImage: "folder")
                    }
                    .disabled(model.isLoading)
                    Button {
                        Task {
                            let requestedPath = externalPath
                            await model.loadExternalCleanupPreview(path: requestedPath)
                            if model.error(for: .cleanup) == nil, model.externalCleanupPreview != nil {
                                previewedExternalPath = requestedPath
                            }
                        }
                    } label: {
                        Label(model.isLoading ? "Previewing" : "Preview Volume", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(model.isLoading || externalPath.isEmpty)
                }

                if let preview = model.externalCleanupPreview, !preview.categories.isEmpty {
                    DataTable {
                        ForEach(preview.categories) { item in
                            CleanupCategoryRow(item: item)
                        }
                    }
                    HStack {
                        Text("\(preview.itemCount) items, \(Formatters.bytes(preview.estimatedBytes))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            showExternalConfirm = true
                        } label: {
                            Label("Clean Volume Metadata", systemImage: "trash")
                        }
                        .disabled(model.isLoading || previewedExternalPath.isEmpty)
                    }
                } else {
                    EmptyStateView(
                        title: "No external volume preview loaded",
                        detail: "Choose a mounted drive under /Volumes to remove macOS metadata such as .Trashes, .TemporaryItems, .DS_Store, and AppleDouble files.",
                        symbol: "externaldrive"
                    )
                }
            }

            ExecutionEventsView(events: model.executionEvents, state: model.executionState)
        }
        .confirmationDialog("Move recoverable files to Trash?", isPresented: $showCleanupConfirm) {
            if !model.isLoading, model.cleanupPreview != nil {
                Button("Move Recoverable Files to Trash", role: .destructive) {
                    guard !model.isLoading else { return }
                    Task { await model.executeCleanupFlow(section: .cleanup) }
                }
            }
            Button("Refresh Preview") {
                Task { await model.loadCleanupPreview() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanupConfirmationMessage)
        }
        .confirmationDialog("Clean selected external volume?", isPresented: $showExternalConfirm) {
            if !model.isLoading, !previewedExternalPath.isEmpty {
                Button("Clean Volume Metadata", role: .destructive) {
                    let pathToClean = previewedExternalPath
                    guard !model.isLoading, !pathToClean.isEmpty else { return }
                    Task {
                        await model.execute(
                            domain: .clean,
                            plan: ExecutionPlan(confirmed: true, externalPath: pathToClean),
                            administrator: true
                        )
                        await model.loadExternalCleanupPreview(path: pathToClean)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(externalCleanupConfirmationMessage)
        }
    }

    private var cleanupConfirmationMessage: String {
        cleanupConfirmationCopy(for: model.cleanupPreview)
    }

    private var externalCleanupConfirmationMessage: String {
        let scope: String
        if let preview = model.externalCleanupPreview {
            scope = "\(Formatters.bytes(preview.estimatedBytes)) across \(preview.itemCount) metadata items in \(preview.categories.count) categories"
        } else {
            scope = "previewed macOS metadata on the selected mounted volume"
        }
        let path = previewedExternalPath.isEmpty ? externalPath : previewedExternalPath
        return "Scope: \(scope) under \(path). Admin: requested so the CLI can inspect volume metadata and then revalidate the mount. Recovery: Trash is used where supported by the volume. Audit: execution events and skipped paths are written to the operation journal."
    }

    private var cleanupMetricValue: String {
        guard let preview = model.cleanupPreview else { return "Not scanned" }
        return Formatters.bytes(preview.estimatedBytes)
    }

    private var cleanupMetricDetail: String {
        guard let preview = model.cleanupPreview else { return "Run cleanup preview" }
        return "\(preview.itemCount) items"
    }

    private var protectedMetricValue: String {
        guard let preview = model.cleanupPreview else { return "Unknown" }
        return "\(preview.protectedCount)"
    }

    private var protectedMetricDetail: String {
        guard let preview = model.cleanupPreview else { return "Preview checks skips" }
        return "\(preview.whitelistCount) whitelist skips"
    }

    private var adminMetricValue: String {
        guard let preview = model.cleanupPreview else { return "Unknown" }
        return preview.adminRequired ? "Needed" : "Not needed"
    }

    private var adminMetricDetail: String {
        model.cleanupPreview == nil ? "Preview checks admin" : "Revalidated by CLI"
    }

    private func startCleanupFlow() {
        if model.cleanupPreview != nil, model.executionState == .previewReady {
            showCleanupConfirm = true
            return
        }
        Task {
            await model.prepareCleanupFlow(section: .cleanup)
            if model.cleanupPreview != nil, model.error(for: .cleanup) == nil {
                showCleanupConfirm = true
            }
        }
    }

    private func chooseExternalVolume() {
        let panel = NSOpenPanel()
        panel.title = "Choose External Volume"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            externalPath = url.path
        }
    }
}

private struct ApplicationsView: View {
    @ObservedObject var model: RoomyViewModel
    @State private var query = ""
    @State private var selectedPath: String?
    @State private var showUninstallConfirm = false

    private var filtered: [InstalledApplication] {
        guard !query.isEmpty else { return model.applications }
        return model.applications.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedApp: InstalledApplication? {
        guard let selectedPath else { return nil }
        return model.applications.first { $0.path == selectedPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Search applications", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Button {
                    Task { await model.loadApplications() }
                } label: {
                    Label(model.isLoading ? "Loading" : "Load Apps", systemImage: "app.badge")
                }
                .disabled(model.isLoading)
            }

            SectionBand(title: "Applications", symbol: "app.dashed") {
                if filtered.isEmpty {
                    EmptyStateView(
                        title: model.applications.isEmpty ? "No application inventory loaded" : "No matching applications",
                        detail: "Load Apps uses Roomy's uninstall inventory and keeps deletion behind confirmation.",
                        symbol: "app.badge"
                    )
                } else {
                    DataTable {
                        ForEach(filtered) { app in
                            Button {
                                selectedPath = app.path
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: app.source == "Homebrew" ? "shippingbox" : "app")
                                        .foregroundStyle(app.source == "Homebrew" ? .orange : .blue)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name).font(.headline)
                                        Text(app.bundleID).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(app.size).monospacedDigit()
                                    Text(app.source)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.blue.opacity(0.10)))
                                    if !app.canUninstall {
                                        Text("Unavailable")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Capsule().fill(Color.gray.opacity(0.12)))
                                    }
                                    Image(systemName: selectedPath == app.path ? "checkmark.circle.fill" : "chevron.right")
                                        .foregroundStyle(selectedPath == app.path ? .green : .secondary)
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let selectedApp {
                SectionBand(title: "Uninstall Preview", symbol: "trash") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedApp.name).font(.headline)
                            Text(selectedApp.path).foregroundStyle(.secondary)
                            if !selectedApp.canUninstall, let reason = selectedApp.uninstallReason, !reason.isEmpty {
                                Text(reason).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            guard selectedApp.canUninstall else { return }
                            Task {
                                await model.execute(
                                    domain: .uninstall,
                                    plan: ExecutionPlan(confirmed: true, dryRun: true, targets: [selectedApp.uninstallName])
                                )
                            }
                        } label: {
                            Label("Preview Uninstall", systemImage: "doc.text.magnifyingglass")
                        }
                        .disabled(model.isLoading || !selectedApp.canUninstall)

                        Button(role: .destructive) {
                            guard selectedApp.canUninstall else { return }
                            showUninstallConfirm = true
                        } label: {
                            Label("Uninstall", systemImage: "trash")
                        }
                        .disabled(model.isLoading || !selectedApp.canUninstall)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
                    )
                }
            }

            ExecutionEventsView(events: model.executionEvents, state: model.executionState)
        }
        .confirmationDialog("Uninstall selected app?", isPresented: $showUninstallConfirm) {
            if !model.isLoading, let selectedApp, selectedApp.canUninstall {
                Button("Uninstall \(selectedApp.name)", role: .destructive) {
                    guard !model.isLoading else { return }
                    Task {
                        await model.execute(
                            domain: .uninstall,
                            plan: ExecutionPlan(confirmed: true, targets: [selectedApp.uninstallName]),
                            administrator: true
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(uninstallConfirmationMessage)
        }
    }

    private var uninstallConfirmationMessage: String {
        guard let selectedApp else {
            return "Scope: the selected application only. Admin: requested for protected app locations. Recovery: files are routed to Trash where supported. Audit: the uninstall run is recorded in the operation journal."
        }
        return "Scope: \(selectedApp.name) at \(selectedApp.path), using uninstall target \(selectedApp.uninstallName). Admin: requested so the CLI can revalidate protected app and support-file locations. Recovery: removable files route to Trash where supported, but app-specific uninstall scripts may not be fully restorable. Audit: preview and uninstall events are recorded in the operation journal."
    }
}

private struct StorageView: View {
    @ObservedObject var model: RoomyViewModel
    @State private var path = NSHomeDirectory()
    @State private var selectedLargeFilePaths: Set<String> = []
    @State private var selectedPurgePaths: Set<String> = []
    @State private var selectedInstallerPaths: Set<String> = []
    @State private var showLargeFileConfirm = false
    @State private var showPurgeConfirm = false
    @State private var showInstallerConfirm = false

    private var selectedLargeFileTargets: [String] {
        let available = Set((model.storageScan?.largeFiles ?? []).map(\.path))
        return selectedLargeFilePaths.filter { available.contains($0) }.sorted()
    }

    private var selectedPurgeTargets: [String] {
        let available = Set((model.purgePreview?.items ?? []).map(\.path))
        return selectedPurgePaths.filter { available.contains($0) }.sorted()
    }

    private var selectedInstallerTargets: [String] {
        let available = Set((model.installerPreview?.items ?? []).map(\.path))
        return selectedInstallerPaths.filter { available.contains($0) }.sorted()
    }

    private var selectedTargetCount: Int {
        selectedLargeFileTargets.count + selectedPurgeTargets.count + selectedInstallerTargets.count
    }

    private var activeStorageScanPath: String {
        model.storageScan?.path ?? path
    }

    private var selectedLargeFileBytes: Int64 {
        (model.storageScan?.largeFiles ?? [])
            .filter { selectedLargeFilePaths.contains($0.path) }
            .reduce(0) { $0 + $1.size }
    }

    private var selectedPurgeBytes: Int64 {
        (model.purgePreview?.items ?? [])
            .filter { selectedPurgePaths.contains($0.path) }
            .reduce(0) { $0 + $1.bytes }
    }

    private var selectedInstallerBytes: Int64 {
        (model.installerPreview?.items ?? [])
            .filter { selectedInstallerPaths.contains($0.path) }
            .reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    scanPreset(NSHomeDirectory())
                } label: {
                    Label("Scan Home", systemImage: "house")
                }
                .disabled(model.isLoading)

                Button {
                    scanPreset(downloadsPath)
                } label: {
                    Label("Scan Downloads", systemImage: "arrow.down.circle")
                }
                .disabled(model.isLoading || !FileManager.default.fileExists(atPath: downloadsPath))

                Button {
                    scanPreset(projectPresetPath)
                } label: {
                    Label("Scan Projects", systemImage: "hammer")
                }
                .disabled(model.isLoading)

                Spacer()
            }

            HStack {
                TextField("Path", text: $path)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 520)
                Button {
                    chooseStorageFolder()
                } label: {
                    Label("Choose", systemImage: "folder")
                }
                .disabled(model.isLoading)
                Button {
                    Task {
                        await model.loadStorage(path: path)
                        selectedLargeFilePaths = []
                    }
                } label: {
                    Label(model.isLoading ? "Scanning" : "Scan", systemImage: "magnifyingglass")
                }
                .disabled(model.isLoading || path.isEmpty)
            }

            HStack(spacing: 14) {
                MetricCard(
                    title: "Scanned",
                    value: Formatters.bytes(model.storageScan?.totalSize ?? 0),
                    detail: model.storageScan?.path ?? path,
                    tint: .blue,
                    symbol: "folder"
                )
                MetricCard(
                    title: "Entries",
                    value: "\(model.storageScan?.entries.count ?? 0)",
                    detail: "\(model.storageScan?.largeFiles.count ?? 0) large files",
                    tint: .green,
                    symbol: "rectangle.stack"
                )
                MetricCard(
                    title: "Removable",
                    value: Formatters.bytes(selectedLargeFileBytes + selectedPurgeBytes + selectedInstallerBytes),
                    detail: "\(selectedTargetCount) selected",
                    tint: .orange,
                    symbol: "trash"
                )
            }

            SectionBand(title: "Largest Entries", symbol: "chart.bar.xaxis") {
                if let scan = model.storageScan, !scan.entries.isEmpty {
                    DataTable {
                        ForEach(scan.entries.prefix(18)) { entry in
                            HStack {
                                Image(systemName: entry.isDir ? "folder" : "doc")
                                    .foregroundStyle(entry.cleanable == true ? .green : .blue)
                                    .frame(width: 22)
                                VStack(alignment: .leading) {
                                    Text(entry.name).font(.headline)
                                    Text(entry.path).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Formatters.bytes(entry.size)).monospacedDigit()
                            }
                            .padding(.vertical, 7)
                        }
                        HiddenCountLine(total: scan.entries.count, visibleLimit: 18, noun: "entries")
                    }
                } else {
                    EmptyStateView(
                        title: "No storage scan loaded",
                        detail: "Choose a readable folder and run Scan.",
                        symbol: "internaldrive"
                    )
                }
            }

            SectionBand(title: "Large Files", symbol: "doc.badge.ellipsis") {
                HStack {
                    Button {
                        selectedLargeFilePaths = Set((model.storageScan?.largeFiles ?? []).prefix(18).map(\.path))
                    } label: {
                        Label("Select Visible", systemImage: "checkmark.circle")
                    }
                    .disabled(model.storageScan?.largeFiles.isEmpty ?? true || model.isLoading)

                    Button {
                        let scanPath = activeStorageScanPath
                        let targets = selectedLargeFileTargets
                        guard !targets.isEmpty else { return }
                        Task {
                            await model.executeStorageAction(
                                operation: "reveal",
                                scanPath: scanPath,
                                targets: targets
                            )
                        }
                    } label: {
                        Label("Reveal", systemImage: "arrow.up.right.square")
                    }
                    .disabled(selectedLargeFileTargets.isEmpty || model.isLoading)

                    Spacer()

                    Text("\(selectedLargeFileTargets.count) selected")
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        showLargeFileConfirm = true
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .disabled(selectedLargeFileTargets.isEmpty || model.isLoading)
                }

                if let scan = model.storageScan, !scan.largeFiles.isEmpty {
                    DataTable {
                        ForEach(scan.largeFiles.prefix(18)) { file in
                            Toggle(isOn: Binding(
                                get: { selectedLargeFilePaths.contains(file.path) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedLargeFilePaths.insert(file.path)
                                    } else {
                                        selectedLargeFilePaths.remove(file.path)
                                    }
                                }
                            )) {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.orange)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name).font(.headline)
                                        Text(file.path).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Formatters.bytes(file.size)).monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 7)
                        }
                        HiddenCountLine(total: scan.largeFiles.count, visibleLimit: 18, noun: "large files")
                    }
                } else {
                    EmptyStateView(
                        title: "No large files loaded",
                        detail: "Run Scan to list large individual files. Roomy revalidates selected paths before moving anything to Trash.",
                        symbol: "doc.badge.ellipsis"
                    )
                }
            }

            SectionBand(title: "Project Artifacts", symbol: "hammer") {
                HStack {
                    Button {
                        Task {
                            await model.loadPurgePreview()
                            selectedPurgePaths = Set((model.purgePreview?.items ?? []).filter { !$0.recent }.map(\.path))
                        }
                    } label: {
                        Label(model.isLoading ? "Scanning" : "Scan Artifacts", systemImage: "magnifyingglass")
                    }
                    .disabled(model.isLoading)

                    Spacer()

                    Text("\(selectedPurgeTargets.count) selected")
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        showPurgeConfirm = true
                    } label: {
                        Label("Clean Artifacts", systemImage: "trash")
                    }
                    .disabled(selectedPurgeTargets.isEmpty || model.isLoading)
                }

                if let preview = model.purgePreview, !preview.items.isEmpty {
                    DataTable {
                        ForEach(preview.items.prefix(18)) { item in
                            Toggle(isOn: Binding(
                                get: { selectedPurgePaths.contains(item.path) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedPurgePaths.insert(item.path)
                                    } else {
                                        selectedPurgePaths.remove(item.path)
                                    }
                                }
                            )) {
                                HStack(spacing: 12) {
                                    Image(systemName: item.recent ? "clock.badge.exclamationmark" : "hammer")
                                        .foregroundStyle(item.recent ? .orange : .green)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.headline)
                                        Text(item.projectRoot).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(item.recent ? "\(item.ageDays)d old" : "safe age")
                                        .font(.caption)
                                        .foregroundStyle(item.recent ? .orange : .secondary)
                                    Text(Formatters.bytes(item.bytes)).monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 7)
                        }
                        HiddenCountLine(total: preview.items.count, visibleLimit: 18, noun: "artifacts")
                    }
                } else {
                    EmptyStateView(
                        title: "No project artifacts loaded",
                        detail: "Scan Artifacts finds rebuildable folders like node_modules, build, dist, Pods, and .build.",
                        symbol: "hammer"
                    )
                }
            }

            SectionBand(title: "Installer Files", symbol: "shippingbox") {
                HStack {
                    Button {
                        Task {
                            await model.loadInstallerPreview()
                            selectedInstallerPaths = Set((model.installerPreview?.items ?? []).map(\.path))
                        }
                    } label: {
                        Label(model.isLoading ? "Scanning" : "Find Installers", systemImage: "magnifyingglass")
                    }
                    .disabled(model.isLoading)

                    Spacer()

                    Text("\(selectedInstallerTargets.count) selected")
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        showInstallerConfirm = true
                    } label: {
                        Label("Remove Installers", systemImage: "trash")
                    }
                    .disabled(selectedInstallerTargets.isEmpty || model.isLoading)
                }

                if let preview = model.installerPreview, !preview.items.isEmpty {
                    DataTable {
                        ForEach(preview.items.prefix(18)) { item in
                            Toggle(isOn: Binding(
                                get: { selectedInstallerPaths.contains(item.path) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedInstallerPaths.insert(item.path)
                                    } else {
                                        selectedInstallerPaths.remove(item.path)
                                    }
                                }
                            )) {
                                HStack(spacing: 12) {
                                    Image(systemName: "shippingbox")
                                        .foregroundStyle(item.source == "Homebrew" ? .orange : .blue)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.headline)
                                        Text(item.path).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(item.source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(Formatters.bytes(item.bytes)).monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 7)
                        }
                        HiddenCountLine(total: preview.items.count, visibleLimit: 18, noun: "installer files")
                    }
                } else {
                    EmptyStateView(
                        title: "No installer files loaded",
                        detail: "Find Installers looks for redundant .dmg, .pkg, .iso, .xip, and installer ZIP files.",
                        symbol: "shippingbox"
                    )
                }
            }

            ExecutionEventsView(events: model.executionEvents, state: model.executionState)
        }
        .confirmationDialog("Move selected large files to Trash?", isPresented: $showLargeFileConfirm) {
            if !model.isLoading, !selectedLargeFileTargets.isEmpty {
                Button("Move \(selectedLargeFileTargets.count) Files to Trash", role: .destructive) {
                    let scanPath = activeStorageScanPath
                    let targets = selectedLargeFileTargets
                    guard !model.isLoading, !targets.isEmpty else { return }
                    Task {
                        await model.executeStorageAction(
                            operation: "trash",
                            scanPath: scanPath,
                            targets: targets
                        )
                        await model.loadStorage(path: scanPath)
                        selectedLargeFilePaths = []
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roomy will revalidate that every selected file is inside the scanned folder, then move it to Trash. Selected size: \(Formatters.bytes(selectedLargeFileBytes)).")
        }
        .confirmationDialog("Clean selected project artifacts?", isPresented: $showPurgeConfirm) {
            if !model.isLoading, !selectedPurgeTargets.isEmpty {
                Button("Clean \(selectedPurgeTargets.count) Artifacts", role: .destructive) {
                    let targets = selectedPurgeTargets
                    guard !model.isLoading, !targets.isEmpty else { return }
                    Task {
                        await model.execute(
                            domain: .purge,
                            plan: ExecutionPlan(confirmed: true, targets: targets)
                        )
                        await model.loadPurgePreview()
                        selectedPurgePaths = Set((model.purgePreview?.items ?? []).filter { !$0.recent }.map(\.path))
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roomy will revalidate each path and move removable artifacts to Trash where supported. Selected size: \(Formatters.bytes(selectedPurgeBytes)).")
        }
        .confirmationDialog("Remove selected installer files?", isPresented: $showInstallerConfirm) {
            if !model.isLoading, !selectedInstallerTargets.isEmpty {
                Button("Remove \(selectedInstallerTargets.count) Installers", role: .destructive) {
                    let targets = selectedInstallerTargets
                    guard !model.isLoading, !targets.isEmpty else { return }
                    Task {
                        await model.execute(
                            domain: .installer,
                            plan: ExecutionPlan(confirmed: true, targets: targets)
                        )
                        await model.loadInstallerPreview()
                        selectedInstallerPaths = Set((model.installerPreview?.items ?? []).map(\.path))
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roomy will revalidate installer file types before removal. Selected size: \(Formatters.bytes(selectedInstallerBytes)).")
        }
    }

    private func chooseStorageFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder to Scan"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func scanPreset(_ newPath: String) {
        path = newPath
        selectedLargeFilePaths = []
        Task {
            await model.loadStorage(path: newPath)
        }
    }

    private var downloadsPath: String {
        "\(NSHomeDirectory())/Downloads"
    }

    private var projectPresetPath: String {
        let candidates = [
            "\(NSHomeDirectory())/Projects",
            "\(NSHomeDirectory())/Code",
            "\(NSHomeDirectory())/Developer",
            "\(NSHomeDirectory())/Documents"
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? candidates[0]
    }
}

private struct PerformanceView: View {
    @ObservedObject var model: RoomyViewModel
    @State private var showOptimizeConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                MetricCard(
                    title: "Memory",
                    value: "\(Int(model.optimizePreview?.memoryUsedGB ?? 0))/\(Int(model.optimizePreview?.memoryTotalGB ?? 0)) GB",
                    detail: "Current working set",
                    tint: .blue,
                    symbol: "memorychip"
                )
                MetricCard(
                    title: "Tasks",
                    value: "\(model.optimizePreview?.optimizations.count ?? 0)",
                    detail: "Previewed optimizations",
                    tint: .green,
                    symbol: "wrench.adjustable"
                )
            }

            SectionBand(title: "Optimization Tasks", symbol: "speedometer") {
                if let preview = model.optimizePreview, !preview.optimizations.isEmpty {
                    DataTable {
                        ForEach(preview.optimizations) { task in
                            HStack(spacing: 12) {
                                Image(systemName: task.safe ? "checkmark.seal" : "exclamationmark.triangle")
                                    .foregroundStyle(task.safe ? .green : .orange)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.name).font(.headline)
                                    Text(task.description).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(task.category.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                } else {
                    EmptyStateView(
                        title: "No optimization preview loaded",
                        detail: "Preview asks Roomy for maintenance tasks before anything runs.",
                        symbol: "speedometer"
                    )
                }
            }

            HStack {
                Button {
                    Task { await model.loadOptimizePreview() }
                } label: {
                    Label(model.isLoading ? "Previewing" : "Preview", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(model.isLoading)

                Button(role: .destructive) {
                    guard model.optimizePreview?.optimizations.isEmpty == false else { return }
                    showOptimizeConfirm = true
                } label: {
                    Label("Run Optimizations", systemImage: "wrench.adjustable")
                }
                .disabled((model.optimizePreview?.optimizations.isEmpty ?? true) || model.isLoading)
            }

            ExecutionEventsView(events: model.executionEvents, state: model.executionState)
        }
        .confirmationDialog("Run optimization tasks?", isPresented: $showOptimizeConfirm) {
            if !model.isLoading, model.optimizePreview?.optimizations.isEmpty == false {
                Button("Run Optimizations", role: .destructive) {
                    guard !model.isLoading else { return }
                    Task {
                        await model.execute(domain: .optimize, plan: ExecutionPlan(confirmed: true), administrator: true)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(optimizeConfirmationMessage)
        }
    }

    private var optimizeConfirmationMessage: String {
        guard let preview = model.optimizePreview else {
            return "Scope: previewed maintenance tasks only. Admin: requested for system-level maintenance. Recovery: optimization changes may not be Trash-restorable. Audit: every task emits execution events."
        }
        let categories = Set(preview.optimizations.map(\.category.capitalized)).sorted().joined(separator: ", ")
        let categoryText = categories.isEmpty ? "maintenance" : categories
        return "Scope: \(preview.optimizations.count) previewed tasks across \(categoryText). Admin: requested because maintenance may touch protected services or caches. Recovery: these are optimization actions, so they may not be restorable from Trash. Audit: each task is streamed to the execution log and operation journal."
    }
}

private func cleanupConfirmationCopy(for preview: CleanupPreview?) -> String {
    guard let preview else {
        return "Scope: recoverable cache, log, and rebuildable files from the latest preview. Admin: checked during preview. Recovery: eligible files move to Trash where supported. Audit: execution events and skipped paths are written to the operation journal."
    }
    let admin = preview.adminRequired ? "needed for at least one previewed category" : "not needed by the preview"
    return "Scope: \(Formatters.bytes(preview.estimatedBytes)) across \(preview.itemCount) recoverable items in \(preview.categoryCount) categories. Admin: \(admin). Recovery: eligible files move to Trash where supported; \(preview.protectedCount) protected and \(preview.whitelistCount) whitelisted paths stay skipped. Audit: execution events and skipped paths are written to the operation journal."
}

private struct MonitorView: View {
    @ObservedObject var model: RoomyViewModel
    @State private var liveRefresh = true

    private let refreshInterval: UInt64 = 5_000_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                MetricCard(title: "CPU", value: Formatters.percent(model.status?.cpu?.usage ?? 0), detail: "Load \(String(format: "%.2f", model.status?.cpu?.load1 ?? 0))", tint: .blue, symbol: "cpu")
                MetricCard(title: "Memory", value: Formatters.percent(model.status?.memory?.usedPercent ?? 0), detail: model.status?.memory?.pressure ?? "pressure unknown", tint: .green, symbol: "memorychip")
                MetricCard(title: "GPU", value: gpuValue, detail: gpuDetail, tint: .purple, symbol: "display")
                MetricCard(title: "Battery", value: batteryValue, detail: model.status?.batteries.first?.health ?? "No battery data", tint: .orange, symbol: "battery.75percent")
                MetricCard(title: "Disk I/O", value: diskIOValue, detail: "Read / write", tint: .blue, symbol: "arrow.up.arrow.down.square")
                MetricCard(title: "Proxy", value: proxyValue, detail: proxyDetail, tint: model.status?.proxy?.enabled == true ? .orange : .green, symbol: "network")
            }

            SectionBand(title: "Hardware Signals", symbol: "sensor") {
                DataTable {
                    InfoLine(title: "Mac", value: hardwareValue, symbol: "macbook")
                    InfoLine(title: "Thermal", value: thermalValue, symbol: "thermometer.medium")
                    InfoLine(title: "Power", value: powerValue, symbol: "bolt")
                }
            }

            SectionBand(title: "Network & Bluetooth", symbol: "antenna.radiowaves.left.and.right") {
                DataTable {
                    ForEach((model.status?.network ?? []).prefix(4)) { network in
                        InfoLine(
                            title: network.name,
                            value: "Down \(String(format: "%.2f", network.rxRateMBs)) MB/s · Up \(String(format: "%.2f", network.txRateMBs)) MB/s",
                            symbol: "network"
                        )
                    }
                    HiddenCountLine(total: model.status?.network.count ?? 0, visibleLimit: 4, noun: "network interfaces")
                    ForEach((model.status?.bluetooth ?? []).prefix(6)) { device in
                        InfoLine(
                            title: device.name,
                            value: device.connected ? "Connected \(device.battery ?? "")" : "Not connected",
                            symbol: "dot.radiowaves.left.and.right"
                        )
                    }
                    HiddenCountLine(total: model.status?.bluetooth.count ?? 0, visibleLimit: 6, noun: "Bluetooth devices")
                }
            }

            SectionBand(title: "Top Processes", symbol: "list.number") {
                if let status = model.status, !status.topProcesses.isEmpty {
                    DataTable {
                        ForEach(status.topProcesses.prefix(12)) { process in
                            HStack {
                                Text(process.name).font(.headline)
                                Spacer()
                                Text("CPU \(process.cpu, specifier: "%.1f")%")
                                    .monospacedDigit()
                                Text("Mem \(process.memory, specifier: "%.1f")%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 7)
                        }
                        HiddenCountLine(total: status.topProcesses.count, visibleLimit: 12, noun: "processes")
                    }
                } else {
                    EmptyStateView(
                        title: "No monitor snapshot loaded",
                        detail: "Refresh asks Roomy for current CPU, memory, disk, battery, network, and process data.",
                        symbol: "waveform.path.ecg"
                    )
                }
            }

            HStack(spacing: 14) {
                Toggle(isOn: $liveRefresh) {
                    Label("Live Refresh", systemImage: "dot.radiowaves.left.and.right")
                }
                .toggleStyle(.switch)

                Text(liveRefresh ? "Updates every 5 seconds" : "Manual refresh")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let collectedAt = model.status?.collectedAt {
                    Text("Last sample \(collectedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await model.loadStatus() }
                } label: {
                    Label(model.isLoading ? "Refreshing" : "Refresh Snapshot", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .task(id: liveRefresh) {
            if model.status == nil, !model.isLoading {
                await model.loadStatus()
            }
            guard liveRefresh else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: refreshInterval)
                guard !Task.isCancelled else { return }
                guard !model.isLoading else { continue }
                await model.loadStatus()
            }
        }
    }

    private var batteryValue: String {
        guard let percent = model.status?.batteries.first?.percent else { return "n/a" }
        return Formatters.percent(percent)
    }

    private var gpuValue: String {
        guard let gpu = model.status?.gpu.first else { return "n/a" }
        if let usage = gpu.usage, usage >= 0 {
            return Formatters.percent(usage)
        }
        if let coreCount = gpu.coreCount {
            return "\(coreCount) cores"
        }
        return gpu.name
    }

    private var gpuDetail: String {
        guard let gpu = model.status?.gpu.first else { return "No GPU data" }
        return gpu.note ?? gpu.name
    }

    private var diskIOValue: String {
        guard let io = model.status?.diskIO else { return "n/a" }
        return "\(String(format: "%.1f", io.readRate))/\(String(format: "%.1f", io.writeRate))"
    }

    private var proxyValue: String {
        guard let proxy = model.status?.proxy else { return "Unknown" }
        return proxy.enabled ? "On" : "Off"
    }

    private var proxyDetail: String {
        guard let proxy = model.status?.proxy else { return "Proxy data unavailable" }
        if proxy.enabled {
            return [proxy.type, proxy.host].compactMap { $0 }.joined(separator: " · ")
        }
        return "No active proxy"
    }

    private var hardwareValue: String {
        guard let hardware = model.status?.hardware else { return model.status?.platform ?? "Unknown Mac" }
        return [hardware.model, hardware.cpuModel, hardware.totalRAM].compactMap { $0 }.joined(separator: " · ")
    }

    private var thermalValue: String {
        guard let thermal = model.status?.thermal else { return "No thermal data" }
        let battery = thermal.batteryTemp.map { "Battery \(Int($0.rounded())) C" }
        let fan = thermal.fanSpeed.map { "Fan \(Int($0.rounded())) RPM" }
        let value = [battery, fan].compactMap { $0 }.joined(separator: " · ")
        return value.isEmpty ? "Quiet" : value
    }

    private var powerValue: String {
        guard let thermal = model.status?.thermal else { return "No power data" }
        let system = thermal.systemPower.map { "System \(String(format: "%.1f", $0))W" }
        let adapter = thermal.adapterPower.map { "Adapter \(String(format: "%.0f", $0))W" }
        return [system, adapter].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct SettingsView: View {
    @ObservedObject var model: RoomyViewModel
    @State private var whitelistMode = "clean"
    @State private var selectedCleanPatterns: Set<String> = []
    @State private var selectedOptimizePatterns: Set<String> = []
    @State private var showTouchIDConfirm = false
    @State private var showCompletionConfirm = false
    @State private var showLaunchersConfirm = false
    @State private var showPrivilegedHelperInstallConfirm = false
    @State private var showPrivilegedHelperUninstallConfirm = false
    @State private var showForceUpdateConfirm = false
    @State private var showNightlyUpdateConfirm = false
    @State private var showRemoveConfirm = false
    @State private var pendingTouchIDAction: String?
    @State private var editablePurgePaths: [String] = []
    @State private var purgePathInput = ""

    private var whitelistItems: [WhitelistItem] {
        whitelistMode == "optimize"
            ? model.optimizeWhitelist?.items ?? []
            : model.cleanWhitelist?.items ?? []
    }

    private var selectedPatterns: Set<String> {
        whitelistMode == "optimize" ? selectedOptimizePatterns : selectedCleanPatterns
    }

    private var privilegedHelperValue: String {
        switch model.privilegedHelperStatus?.state {
        case .enabled:
            "Enabled"
        case .requiresApproval:
            "Needs approval"
        case .notRegistered:
            "Not installed"
        case .notFound:
            "Missing"
        case .unavailable:
            "Unavailable"
        case .unknown, nil:
            "Unknown"
        }
    }

    private var privilegedHelperTint: Color {
        switch model.privilegedHelperStatus?.state {
        case .enabled:
            .green
        case .requiresApproval, .notRegistered:
            .orange
        default:
            .blue
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionBand(title: "CLI Location", symbol: "terminal") {
                HStack {
                    Text(model.cliPath)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 8)
            }

            SectionBand(title: "Safety Defaults", symbol: "shield.lefthalf.filled") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsRow(title: "Destructive flows", value: "Preview before execute")
                    SettingsRow(title: "Delete mode", value: cleanupDeleteModeValue)
                    SettingsRow(title: "Whitelist skips", value: cleanupWhitelistValue)
                    SettingsRow(title: "Config", value: model.configPath)
                    SettingsRow(title: "Logs", value: model.logPath)
                    SettingsRow(title: "Privileged helper", value: privilegedHelperValue)
                    SettingsRow(title: "Touch ID for sudo", value: touchIDValue)
                    SettingsRow(title: "Shell completion", value: completionValue)
                }
            }

            SectionBand(title: "Privileged Helper", symbol: "lock.badge.checkmark") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    IntegrationStatusCard(
                        title: "Admin Cleanup",
                        value: privilegedHelperValue,
                        detail: model.privilegedHelperStatus?.detail ?? "Helper status not loaded",
                        symbol: "lock.badge.checkmark",
                        tint: privilegedHelperTint
                    )
                }

                HStack(spacing: 10) {
                    Button {
                        showPrivilegedHelperInstallConfirm = true
                    } label: {
                        Label("Install Helper", systemImage: "checkmark.shield")
                    }
                    .disabled(model.privilegedHelperStatus?.state == .enabled || model.isLoading)

                    Button(role: .destructive) {
                        showPrivilegedHelperUninstallConfirm = true
                    } label: {
                        Label("Remove Helper", systemImage: "xmark.shield")
                    }
                    .disabled(model.privilegedHelperStatus?.state != .enabled || model.isLoading)
                }
            }

            SectionBand(title: "System Integration", symbol: "touchid") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 12)], spacing: 12) {
                    IntegrationStatusCard(
                        title: "Touch ID",
                        value: touchIDValue,
                        detail: model.touchIDStatus?.supported == true ? "Use macOS authorization for sudo changes" : "This Mac does not report Touch ID support",
                        symbol: "touchid",
                        tint: model.touchIDStatus?.configured == true ? .green : .orange
                    )
                    IntegrationStatusCard(
                        title: "Shell Completion",
                        value: completionValue,
                        detail: model.completionStatus?.configFile ?? "Shell config not loaded",
                        symbol: "terminal",
                        tint: model.completionStatus?.installed == true ? .green : .blue
                    )
                    IntegrationStatusCard(
                        title: "Quick Launchers",
                        value: launcherValue,
                        detail: model.launcherStatus?.raycastDir ?? "Raycast and Alfred setup not loaded",
                        symbol: "sparkle.magnifyingglass",
                        tint: model.launcherStatus?.raycastInstalled == true ? .green : .blue
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    Button {
                        Task {
                            await model.executeTouchID(action: touchIDAction, dryRun: true)
                        }
                    } label: {
                        Label("Preview Touch ID", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(model.touchIDStatus?.supported == false || model.isLoading)

                    Button {
                        pendingTouchIDAction = touchIDAction
                        showTouchIDConfirm = true
                    } label: {
                        Label(model.touchIDStatus?.configured == true ? "Disable Touch ID" : "Enable Touch ID", systemImage: "touchid")
                    }
                    .disabled(model.touchIDStatus?.supported == false || model.isLoading)

                    Button {
                        Task { await model.executeCompletion(dryRun: true) }
                    } label: {
                        Label("Preview Completion", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(model.isLoading)

                    Button {
                        showCompletionConfirm = true
                    } label: {
                        Label("Install Completion", systemImage: "terminal")
                    }
                    .disabled(model.completionStatus?.installed == true || model.isLoading)

                    Button {
                        Task { await model.executeLaunchers(dryRun: true) }
                    } label: {
                        Label("Preview Launchers", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(model.isLoading)

                    Button {
                        showLaunchersConfirm = true
                    } label: {
                        Label("Install Launchers", systemImage: "sparkle.magnifyingglass")
                    }
                    .disabled(model.launcherStatus?.raycastInstalled == true && model.launcherStatus?.alfredInstalled == true || model.isLoading)
                }
            }

            SectionBand(title: "Roomy Maintenance", symbol: "arrow.triangle.2.circlepath") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    IntegrationStatusCard(
                        title: "Installed Roomy",
                        value: maintenanceValue,
                        detail: model.maintenanceStatus?.cliPath ?? model.cliPath,
                        symbol: "app.badge.checkmark",
                        tint: .green
                    )
                    IntegrationStatusCard(
                        title: "Channel",
                        value: model.maintenanceStatus?.channel.capitalized ?? "Unknown",
                        detail: model.maintenanceStatus?.installMethod.capitalized ?? "Install method unknown",
                        symbol: "point.3.connected.trianglepath.dotted",
                        tint: .blue
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                    Button {
                        Task {
                            await model.execute(
                                domain: .update,
                                plan: ExecutionPlan(confirmed: true, dryRun: true)
                            )
                        }
                    } label: {
                        Label("Preview Update", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(model.isLoading)

                    Button {
                        showForceUpdateConfirm = true
                    } label: {
                        Label("Force Stable Update", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.isLoading)

                    Button {
                        showNightlyUpdateConfirm = true
                    } label: {
                        Label("Install Nightly", systemImage: "moon.stars")
                    }
                    .disabled(model.isLoading)

                    Button {
                        Task {
                            await model.execute(
                                domain: .remove,
                                plan: ExecutionPlan(confirmed: true, dryRun: true)
                            )
                        }
                    } label: {
                        Label("Preview Remove", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(model.isLoading)

                    Button(role: .destructive) {
                        showRemoveConfirm = true
                    } label: {
                        Label("Remove Roomy", systemImage: "trash")
                    }
                    .disabled(model.isLoading)
                }
            }

            SectionBand(title: "Project Scan Paths", symbol: "folder.badge.gearshape") {
                HStack {
                    TextField("Add project folder path", text: $purgePathInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                    Button {
                        addPurgePath()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(purgePathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        editablePurgePaths = model.purgePaths?.defaultPaths ?? []
                    } label: {
                        Label("Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(model.isLoading)

                    Spacer()

                    Button {
                        Task {
                            await model.updatePurgePaths(paths: editablePurgePaths)
                            syncPurgePathsFromModel()
                        }
                    } label: {
                        Label("Save Paths", systemImage: "checkmark.circle")
                    }
                    .disabled(model.isLoading)
                }

                if model.purgePaths != nil || !editablePurgePaths.isEmpty {
                    DataTable {
                        ForEach(editablePurgePaths, id: \.self) { path in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.blue)
                                    .frame(width: 22)
                                Text(path)
                                Spacer()
                                Text(FileManager.default.fileExists(atPath: path) ? "Ready" : "Missing")
                                    .foregroundStyle(FileManager.default.fileExists(atPath: path) ? .green : .orange)
                                Button {
                                    editablePurgePaths.removeAll { $0 == path }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(model.isLoading)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                } else {
                    EmptyStateView(
                        title: "No purge paths loaded",
                        detail: "Load Settings to show the folders Roomy scans for project artifacts.",
                        symbol: "folder.badge.gearshape"
                    )
                }
            }

            SectionBand(title: "Protection Lists", symbol: "checklist.checked") {
                HStack {
                    Picker("Mode", selection: $whitelistMode) {
                        Text("Cleanup").tag("clean")
                        Text("Performance").tag("optimize")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)

                    Spacer()

                    Text("\(selectedPatterns.count) protected")
                        .foregroundStyle(.secondary)

                    Button {
                        saveWhitelist()
                    } label: {
                        Label("Save Protection", systemImage: "checkmark.shield")
                    }
                    .disabled(model.isLoading || whitelistItems.isEmpty)
                }

                if whitelistItems.isEmpty {
                    EmptyStateView(
                        title: "No protection list loaded",
                        detail: "Load Settings to review caches and optimization tasks Roomy should protect.",
                        symbol: "checklist.checked"
                    )
                } else {
                    DataTable {
                        ForEach(whitelistItems.prefix(28)) { item in
                            Toggle(isOn: Binding(
                                get: { isSelected(item.pattern) },
                                set: { setSelected($0, pattern: item.pattern) }
                            )) {
                                HStack(spacing: 12) {
                                    Image(systemName: item.category == "custom" ? "slider.horizontal.3" : "shield")
                                        .foregroundStyle(isSelected(item.pattern) ? .green : .secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.name).font(.headline)
                                        Text(item.pattern).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(item.category.replacingOccurrences(of: "_", with: " "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.vertical, 7)
                        }
                        HiddenCountLine(total: whitelistItems.count, visibleLimit: 28, noun: "protection rules")
                    }
                }
            }

            SectionBand(title: "Permissions", symbol: "lock.shield") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        IntegrationStatusCard(
                            title: "Full Disk Access",
                            value: model.fullDiskAccessStatus.displayValue,
                            detail: model.fullDiskAccessStatus.detail,
                            symbol: "lock.shield",
                            tint: fullDiskAccessTint
                        )

                        Spacer()

                        Button {
                            openFullDiskAccessSettings()
                        } label: {
                            Label("Open Full Disk Access", systemImage: "gearshape")
                        }

                        Button {
                            model.refreshFullDiskAccessStatus()
                        } label: {
                            Label("Check Again", systemImage: "arrow.clockwise")
                        }
                    }

                    NoticeView(
                        text: "Full Disk Access is managed in System Settings. Roomy revalidates paths in the CLI before deletion, so the app never acts as deletion authority.",
                        symbol: "lock.shield",
                        tint: .blue
                    )
                }
            }

            HStack {
                Button {
                    Task {
                        await model.loadSettings()
                        syncSelectionsFromModel()
                        syncPurgePathsFromModel()
                    }
                } label: {
                    Label(model.isLoading ? "Loading" : "Load Settings", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }

            ExecutionEventsView(events: model.executionEvents, state: model.executionState)
        }
        .onChange(of: model.cleanWhitelist) { _ in
            syncSelectionsFromModel()
        }
        .onChange(of: model.optimizeWhitelist) { _ in
            syncSelectionsFromModel()
        }
        .onChange(of: model.purgePaths) { _ in
            syncPurgePathsFromModel()
        }
        .confirmationDialog("Install privileged helper?", isPresented: $showPrivilegedHelperInstallConfirm) {
            if !model.isLoading, model.privilegedHelperStatus?.state != .enabled {
                Button("Install Helper") {
                    guard !model.isLoading else { return }
                    Task { await model.installPrivilegedHelper() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will register Roomy's bundled launch daemon so cleanup can run admin work through the helper instead of password dialogs in the app.")
        }
        .confirmationDialog("Remove privileged helper?", isPresented: $showPrivilegedHelperUninstallConfirm) {
            if !model.isLoading, model.privilegedHelperStatus?.state == .enabled {
                Button("Remove Helper", role: .destructive) {
                    guard !model.isLoading else { return }
                    Task { await model.uninstallPrivilegedHelper() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roomy will unregister the launch daemon. Admin cleanup will be unavailable until the helper is installed again.")
        }
        .confirmationDialog("Change Touch ID sudo setting?", isPresented: $showTouchIDConfirm) {
            if !model.isLoading, let action = pendingTouchIDAction, model.touchIDStatus?.supported != false {
                Button(action == "disable" ? "Disable Touch ID" : "Enable Touch ID") {
                    guard !model.isLoading else { return }
                    Task {
                        await model.executeTouchID(action: action, administrator: true)
                        pendingTouchIDAction = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingTouchIDAction = nil
            }
        } message: {
            Text("macOS will ask for administrator authorization. Roomy modifies sudo configuration through its existing Touch ID helper.")
        }
        .confirmationDialog("Install shell completion?", isPresented: $showCompletionConfirm) {
            if !model.isLoading, model.completionStatus?.installed != true {
                Button("Install Completion") {
                    guard !model.isLoading else { return }
                    Task { await model.executeCompletion() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roomy will update the shell config file shown in Settings so roomy commands autocomplete in new terminal sessions.")
        }
        .confirmationDialog("Install Raycast and Alfred launchers?", isPresented: $showLaunchersConfirm) {
            if !model.isLoading, !(model.launcherStatus?.raycastInstalled == true && model.launcherStatus?.alfredInstalled == true) {
                Button("Install Launchers") {
                    guard !model.isLoading else { return }
                    Task { await model.executeLaunchers() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roomy will create Raycast script commands and Alfred workflows for Clean, Uninstall, Optimize, Analyze, and Status.")
        }
        .confirmationDialog("Force Roomy stable update?", isPresented: $showForceUpdateConfirm) {
            if !model.isLoading {
                Button("Force Stable Update") {
                    guard !model.isLoading else { return }
                    Task {
                        await model.execute(
                            domain: .update,
                            plan: ExecutionPlan(confirmed: true, force: true),
                            administrator: true
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roomy will run its existing update workflow. macOS may ask for administrator authorization if the install location needs it.")
        }
        .confirmationDialog("Install nightly Roomy build?", isPresented: $showNightlyUpdateConfirm) {
            if !model.isLoading {
                Button("Install Nightly") {
                    guard !model.isLoading else { return }
                    Task {
                        await model.execute(
                            domain: .update,
                            plan: ExecutionPlan(confirmed: true, nightly: true),
                            administrator: true
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nightly uses Roomy's main-branch installer and is intended for testing unreleased fixes.")
        }
        .confirmationDialog("Remove Roomy from this Mac?", isPresented: $showRemoveConfirm) {
            if !model.isLoading {
                Button("Remove Roomy", role: .destructive) {
                    guard !model.isLoading else { return }
                    Task {
                        await model.execute(
                            domain: .remove,
                            plan: ExecutionPlan(confirmed: true),
                            administrator: true
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Roomy will run its existing removal flow and re-check detected install paths before deleting.")
        }
    }

    private var touchIDValue: String {
        guard let status = model.touchIDStatus else { return "Unknown" }
        if !status.supported { return "Not supported" }
        return status.configured ? "Enabled" : "Not configured"
    }

    private var touchIDAction: String {
        model.touchIDStatus?.configured == true ? "disable" : "enable"
    }

    private var completionValue: String {
        guard let status = model.completionStatus else { return "Unknown" }
        return status.installed ? "Installed for \(status.shell)" : "Not installed for \(status.shell)"
    }

    private var launcherValue: String {
        guard let status = model.launcherStatus else { return "Unknown" }
        if status.raycastInstalled && (status.alfredInstalled || !status.alfredAvailable) {
            return "Ready"
        }
        if status.raycastCount > 0 || status.alfredCount > 0 {
            return "\(status.raycastCount + status.alfredCount) installed"
        }
        return "Not installed"
    }

    private var maintenanceValue: String {
        guard let status = model.maintenanceStatus else { return "Unknown" }
        return "v\(status.version)"
    }

    private var fullDiskAccessTint: Color {
        switch model.fullDiskAccessStatus.state {
        case .enabled:
            .green
        case .limited:
            .orange
        case .unknown:
            .blue
        }
    }

    private var cleanupDeleteModeValue: String {
        model.cleanupPreview?.deleteMode ?? "Preview not loaded"
    }

    private var cleanupWhitelistValue: String {
        guard let preview = model.cleanupPreview else { return "Preview not loaded" }
        return "\(preview.whitelistCount)"
    }

    private func syncSelectionsFromModel() {
        selectedCleanPatterns = Set((model.cleanWhitelist?.items ?? []).filter(\.selected).map(\.pattern))
        selectedOptimizePatterns = Set((model.optimizeWhitelist?.items ?? []).filter(\.selected).map(\.pattern))
    }

    private func syncPurgePathsFromModel() {
        editablePurgePaths = model.purgePaths?.paths ?? []
    }

    private func addPurgePath() {
        let trimmed = purgePathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !editablePurgePaths.contains(trimmed) {
            editablePurgePaths.append(trimmed)
        }
        purgePathInput = ""
    }

    private func isSelected(_ pattern: String) -> Bool {
        selectedPatterns.contains(pattern)
    }

    private func setSelected(_ selected: Bool, pattern: String) {
        if whitelistMode == "optimize" {
            if selected {
                selectedOptimizePatterns.insert(pattern)
            } else {
                selectedOptimizePatterns.remove(pattern)
            }
        } else {
            if selected {
                selectedCleanPatterns.insert(pattern)
            } else {
                selectedCleanPatterns.remove(pattern)
            }
        }
    }

    private func saveWhitelist() {
        let mode = whitelistMode
        let patterns = Array(selectedPatterns).sorted()
        Task {
            await model.updateWhitelist(mode: mode, patterns: patterns)
            syncSelectionsFromModel()
        }
    }
}

private struct HealthScoreCard: View {
    var score: Int
    var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(score)")
                    .font(.system(size: 54, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("/ 100")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "heart.text.square")
                    .font(.title2)
                    .foregroundStyle(score > 80 ? .green : .orange)
            }
            ProgressView(value: Double(score), total: 100)
                .tint(score > 80 ? .green : .orange)
            Text(message ?? "System care ready")
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .panelStyle(minHeight: 150)
    }
}

private struct CleanupFlowPanel: View {
    var preview: CleanupPreview?
    var executionState: PreviewExecutionState
    var isLoading: Bool
    var onPreview: () -> Void
    var onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Cleanup Plan", systemImage: "sparkles")
                        .font(.title3.weight(.semibold))
                    Text(summary)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SafetyPill(text: "Preview cleanup", symbol: "doc.text.magnifyingglass")
                        SafetyPill(text: "Review plan", symbol: "list.bullet.rectangle")
                        SafetyPill(text: "Trash-backed", symbol: "trash")
                        SafetyPill(text: "Protected paths skipped", symbol: "checkmark.shield")
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 10) {
                    Button(action: onPreview) {
                        Label(primaryButtonTitle, systemImage: primaryButtonSymbol)
                            .frame(minWidth: 154)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isLoading || executionState == .running)

                    Button(action: onReview) {
                        Label("Review Plan", systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                }
            }

            ProgressRail(steps: progressSteps)
        }
        .panelStyle(minHeight: 174)
    }

    private var summary: String {
        switch executionState {
        case .completed:
            return "Cleanup finished. Recent activity shows what was moved, skipped, or left alone."
        case .running:
            return "Roomy is moving approved recoverable files to Trash."
        case .failed(let message):
            return message
        default:
            if let preview {
                return "\(Formatters.bytes(preview.estimatedBytes)) is ready for review across \(preview.itemCount) recoverable items."
            }
            return "Preview recoverable cache, log, and rebuildable files, review the plan, then move approved items to Trash."
        }
    }

    private var primaryButtonTitle: String {
        if isLoading { return "Checking" }
        switch executionState {
        case .running:
            return "Moving"
        case .completed:
            return "Preview Again"
        case .previewReady:
            return "Move to Trash"
        default:
            return "Preview Cleanup"
        }
    }

    private var primaryButtonSymbol: String {
        switch executionState {
        case .running:
            return "hourglass"
        case .completed:
            return "arrow.clockwise"
        case .previewReady:
            return "trash"
        default:
            return "doc.text.magnifyingglass"
        }
    }

    private var progressSteps: [ProgressRail.Step] {
        [
            ProgressRail.Step(
                title: "Preview Cleanup",
                value: preview == nil ? "Needed" : Formatters.bytes(preview?.estimatedBytes ?? 0),
                symbol: "doc.text.magnifyingglass",
                state: preview == nil ? .waiting : .complete
            ),
            ProgressRail.Step(
                title: "Review Plan",
                value: preview == nil ? "Not ready" : "\(preview?.itemCount ?? 0) items",
                symbol: "list.bullet.rectangle",
                state: preview == nil ? .waiting : .complete
            ),
            ProgressRail.Step(
                title: "Move to Trash",
                value: trashStepValue,
                symbol: "trash",
                state: trashStepState
            )
        ]
    }

    private var trashStepValue: String {
        switch executionState {
        case .running:
            return "Running"
        case .completed:
            return "Done"
        case .previewReady:
            return "Confirm"
        default:
            return "After review"
        }
    }

    private var trashStepState: ProgressRail.StepState {
        switch executionState {
        case .running:
            return .active
        case .completed:
            return .complete
        default:
            return .waiting
        }
    }
}

private struct ProgressRail: View {
    enum StepState {
        case waiting
        case active
        case complete
    }

    struct Step: Identifiable {
        var title: String
        var value: String
        var symbol: String
        var state: StepState

        var id: String { title }
    }

    var steps: [Step]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    Image(systemName: step.symbol)
                        .foregroundStyle(color(for: step.state))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .font(.caption.weight(.semibold))
                        Text(step.value)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color(for: step.state).opacity(step.state == .waiting ? 0.06 : 0.12))
                )
            }
        }
    }

    private func color(for state: StepState) -> Color {
        switch state {
        case .waiting:
            .secondary
        case .active:
            .orange
        case .complete:
            .green
        }
    }
}

private struct SafetyPill: View {
    var text: String
    var symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.06))
            )
    }
}

private struct MetricCard: View {
    var title: String
    var value: String
    var detail: String
    var tint: Color
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                Spacer()
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .panelStyle(minHeight: 150)
    }
}

private struct IntegrationStatusCard: View {
    var title: String
    var value: String
    var detail: String
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .panelStyle(minHeight: 112)
    }
}

private struct SectionBand<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DataTable<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LiquidGlassSurface(cornerRadius: 8))
    }
}

private struct HiddenCountLine: View {
    var total: Int
    var visibleLimit: Int
    var noun: String

    private var hiddenCount: Int {
        max(0, total - visibleLimit)
    }

    private var visibleCount: Int {
        min(total, visibleLimit)
    }

    var body: some View {
        if hiddenCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text("Showing \(visibleCount) of \(total); \(hiddenCount) more \(noun) hidden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 7)
        }
    }
}

private struct CleanupCategoryRow: View {
    var item: CleanupCategory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                Text("\(item.section) · \(item.riskReason)").foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(item.itemCount) items")
                .foregroundStyle(.secondary)
            Text(Formatters.bytes(item.estimatedBytes))
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
    }

    private var iconName: String {
        item.adminRequired ? "lock.trianglebadge.exclamationmark" : "checkmark.shield"
    }

    private var tint: Color {
        switch item.risk {
        case "HIGH": .orange
        case "LOW": .green
        default: .blue
        }
    }
}

private struct ActionRow: View {
    var title: String
    var detail: String
    var symbol: String = "arrow.right.circle.fill"
    var tint: Color = .blue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(LiquidGlassSurface(cornerRadius: 8))
    }
}

private struct RecoveryReportPanel: View {
    var entries: [OperationJournalEntry]
    var logPath: String
    var isLoading: Bool
    var onRefresh: () -> Void

    var body: some View {
        SectionBand(title: "Recovery & Reports", symbol: "arrow.uturn.backward.circle") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 12)], spacing: 12) {
                    IntegrationStatusCard(
                        title: "Restore",
                        value: recoveryValue,
                        detail: "roomy restore list checks which Trash-backed items are still resolvable.",
                        symbol: "arrow.uturn.backward.circle",
                        tint: trashedCount > 0 ? .green : .blue
                    )
                    IntegrationStatusCard(
                        title: "Report",
                        value: reportValue,
                        detail: "roomy report --last 30d summarizes sessions, actions, and top paths.",
                        symbol: "chart.bar.xaxis",
                        tint: .blue
                    )
                    IntegrationStatusCard(
                        title: "Audit Trail",
                        value: "\(entries.count) loaded",
                        detail: logPath,
                        symbol: "doc.text.magnifyingglass",
                        tint: failedCount > 0 ? .orange : .green
                    )
                }

                HStack {
                    if let latestEntry = entries.first {
                        Text("Latest: \(latestEntry.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("No journal entries loaded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onRefresh) {
                        Label("Refresh Journal", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
    }

    private var trashedCount: Int {
        entries.filter { $0.action == "TRASHED" }.count
    }

    private var sessionCount: Int {
        entries.filter { $0.recordType == "session" && $0.action == "ENDED" }.count
    }

    private var failedCount: Int {
        entries.filter { $0.event == "failed" || $0.action == "FAILED" }.count
    }

    private var recoveryValue: String {
        if trashedCount == 0 {
            return "No recent items"
        }
        return "\(trashedCount) recent"
    }

    private var reportValue: String {
        if sessionCount == 0 {
            return "Ready"
        }
        return "\(sessionCount) sessions"
    }
}

private struct PermissionOnboardingCard: View {
    @ObservedObject var model: RoomyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: permissionSymbol)
                    .font(.title2)
                    .foregroundStyle(permissionTint)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Set scan access")
                        .font(.title3.weight(.semibold))
                    Text(model.fullDiskAccessStatus.detail)
                        .foregroundStyle(.secondary)
                    Text("Without Full Disk Access, Roomy can still scan folders you choose and run previews. With it, Roomy can produce complete results without repeated macOS folder prompts.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(model.fullDiskAccessStatus.displayValue)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(permissionTint.opacity(0.12)))
                    .foregroundStyle(permissionTint)
            }

            HStack(spacing: 10) {
                Button {
                    openFullDiskAccessSettings()
                } label: {
                    Label("Open Full Disk Access", systemImage: "gearshape")
                }

                Button {
                    model.refreshFullDiskAccessStatus()
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }

                Spacer()

                Button {
                    model.continueWithLimitedAccess()
                } label: {
                    Label("Continue Limited", systemImage: "arrow.right")
                }
            }
        }
        .padding(16)
        .background(LiquidGlassSurface(cornerRadius: 8, tint: permissionTint.opacity(0.06)))
    }

    private var permissionTint: Color {
        switch model.fullDiskAccessStatus.state {
        case .enabled:
            .green
        case .limited:
            .orange
        case .unknown:
            .blue
        }
    }

    private var permissionSymbol: String {
        switch model.fullDiskAccessStatus.state {
        case .enabled:
            "checkmark.shield"
        case .limited:
            "lock.shield"
        case .unknown:
            "questionmark.shield"
        }
    }
}

private struct OperationJournalRow: View {
    var entry: OperationJournalEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.headline)
                Text(entry.summary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(entry.timestamp)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 7)
    }

    private var symbol: String {
        if entry.event == "failed" || entry.action == "FAILED" {
            return "exclamationmark.triangle"
        }
        if entry.event == "completed" || entry.action == "REMOVED" || entry.action == "TRASHED" {
            return "checkmark.circle"
        }
        if entry.recordType == "session" {
            return "terminal"
        }
        return "doc.text"
    }

    private var tint: Color {
        if entry.event == "failed" || entry.action == "FAILED" {
            return .orange
        }
        if entry.event == "completed" || entry.action == "REMOVED" || entry.action == "TRASHED" {
            return .green
        }
        return .blue
    }
}

private struct PermissionPill: View {
    var title: String
    var active: Bool
    var value: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: active ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(active ? .green : .orange)
            Text(title)
            Text(value ?? (active ? "Ready" : "Review"))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.34))
                )
        )
    }
}

private struct SettingsRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }
}

private struct InfoLine: View {
    var title: String
    var value: String
    var symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
                .frame(width: 22)
            Text(title).font(.headline)
            Spacer()
            Text(value.isEmpty ? "n/a" : value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 6)
    }
}

private struct EmptyStateView: View {
    var title: String
    var detail: String
    var symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(LiquidGlassSurface(cornerRadius: 8))
    }
}

private struct ExecutionEventsView: View {
    var events: [ExecutionEvent]
    var state: PreviewExecutionState

    var body: some View {
        if !events.isEmpty || stateMessage != nil {
            SectionBand(title: "Execution Log", symbol: "terminal") {
                DataTable {
                    if let cleanupSummary {
                        CleanupSuccessSummary(event: cleanupSummary)
                    } else if let recoveryMessage {
                        FailureRecoveryRow(message: recoveryMessage)
                    } else if let stateMessage {
                        EventLine(symbol: stateSymbol, tint: stateTint, text: stateMessage)
                    }
                    ForEach(logEvents) { event in
                        EventLine(
                            symbol: symbol(for: event.event),
                            tint: tint(for: event.event),
                            text: displayText(for: event)
                        )
                    }
                }
            }
        }
    }

    private var cleanupSummary: ExecutionEvent? {
        events.last { event in
            event.domain == "clean" && event.event == "completed" && event.bytes != nil
        }
    }

    private var logEvents: [ExecutionEvent] {
        let summaryID = cleanupSummary?.id
        return events.suffix(8).filter { event in
            event.id != summaryID && !isDuplicateCleanupSummaryLine(event)
        }
    }

    private var stateMessage: String? {
        switch state {
        case .idle, .previewReady:
            nil
        case .confirming:
            "Waiting for confirmation"
        case .running:
            "Running Roomy command"
        case .completed:
            "Completed"
        case let .failed(message):
            message
        }
    }

    private var recoveryMessage: String? {
        if case let .failed(message) = state {
            return message
        }
        return nil
    }

    private var stateSymbol: String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .running: "play.circle.fill"
        default: "info.circle"
        }
    }

    private var stateTint: Color {
        switch state {
        case .completed: .green
        case .failed: .orange
        case .running: .blue
        default: .secondary
        }
    }

    private func symbol(for event: String) -> String {
        switch event {
        case "completed": "checkmark.circle.fill"
        case "failed", "warning": "exclamationmark.triangle.fill"
        case "skipped": "forward.circle.fill"
        default: "smallcircle.filled.circle"
        }
    }

    private func tint(for event: String) -> Color {
        switch event {
        case "completed": .green
        case "failed", "warning": .orange
        case "skipped": .secondary
        default: .blue
        }
    }

    private func displayText(for event: ExecutionEvent) -> String {
        if event.domain == "clean", event.event == "completed", let bytes = event.bytes {
            var parts = ["Space freed: \(Formatters.cleanupBytes(bytes))"]
            if let itemCount = event.itemCount {
                parts.append("Items cleaned: \(itemCount)")
            }
            if let categoryCount = event.categoryCount {
                parts.append("Categories: \(categoryCount)")
            }
            if let equivalent = event.equivalent, !equivalent.isEmpty {
                parts.append(equivalent)
            }
            if let freeSpace = event.freeSpace, !freeSpace.isEmpty {
                parts.append("Free space now: \(freeSpace)")
            }
            return parts.joined(separator: " | ")
        }
        return event.message ?? event.event.capitalized
    }

    private func isDuplicateCleanupSummaryLine(_ event: ExecutionEvent) -> Bool {
        guard cleanupSummary != nil, event.domain == "clean", event.event == "progress" else {
            return false
        }
        let message = event.message ?? ""
        return message.contains("Cleanup complete") ||
            message.contains("Space freed:") ||
            message.contains("Equivalent to ~") ||
            message.contains("Free space now:")
    }
}

private struct FailureRecoveryRow: View {
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Action stopped")
                    .font(.system(.headline, design: .monospaced))
            }
            Text(message)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Review the plan, permissions, and operation journal before retrying.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct CleanupSuccessSummary: View {
    var event: ExecutionEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Cleanup complete")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            Text(metricsLine)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            if let equivalent = event.equivalent, !equivalent.isEmpty {
                Text(equivalent)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let freeSpace = event.freeSpace, !freeSpace.isEmpty {
                Text("Free space now: \(freeSpace)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var metricsLine: String {
        var parts = ["Space freed: \(Formatters.cleanupBytes(event.bytes ?? 0))"]
        if let itemCount = event.itemCount {
            parts.append("Items cleaned: \(itemCount)")
        }
        if let categoryCount = event.categoryCount {
            parts.append("Categories: \(categoryCount)")
        }
        return parts.joined(separator: " | ")
    }
}

private struct EventLine: View {
    var symbol: String
    var tint: Color
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer()
        }
        .padding(.vertical, 5)
    }
}

private struct NoticeView: View {
    var text: String
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
        .background(LiquidGlassSurface(cornerRadius: 8, tint: tint.opacity(0.06)))
    }
}

private struct LiquidGlassSurface: View {
    var cornerRadius: CGFloat
    var tint: Color = .clear

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.025), radius: 8, x: 0, y: 3)
    }
}

private func openFullDiskAccessSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
        return
    }
    NSWorkspace.shared.open(url)
}

private extension View {
    func panelStyle(minHeight: CGFloat) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(LiquidGlassSurface(cornerRadius: 8))
    }
}
