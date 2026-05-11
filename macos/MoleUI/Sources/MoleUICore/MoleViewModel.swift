import Foundation
import SwiftUI

@MainActor
public final class MoleViewModel: ObservableObject {
    @Published public var selectedSection: MoleSection = .home
    @Published public var status: StatusSnapshot?
    @Published public var cleanupPreview: CleanupPreview?
    @Published public var externalCleanupPreview: CleanupPreview?
    @Published public var applications: [InstalledApplication] = []
    @Published public var storageScan: StorageScan?
    @Published public var optimizePreview: OptimizePreview?
    @Published public var purgePreview: PurgePreview?
    @Published public var installerPreview: InstallerPreview?
    @Published public var cleanWhitelist: WhitelistResponse?
    @Published public var optimizeWhitelist: WhitelistResponse?
    @Published public var purgePaths: PurgePathsResponse?
    @Published public var touchIDStatus: TouchIDStatus?
    @Published public var completionStatus: CompletionStatus?
    @Published public var launcherStatus: LauncherStatus?
    @Published public var maintenanceStatus: MoleMaintenanceStatus?
    @Published public var privilegedHelperStatus: PrivilegedHelperStatusSnapshot?
    @Published public var executionEvents: [ExecutionEvent] = []
    @Published public var executionState: PreviewExecutionState = .idle
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var sectionErrors: [MoleSection: String] = [:]
    @Published public var cliPath: String
    @Published public var configPath: String
    @Published public var logPath: String

    public var apiClient: MoleAPIClient
    public var privilegedHelperInstaller: MolePrivilegedHelperInstaller

    public init(
        apiClient: MoleAPIClient = MoleAPIClient(),
        privilegedHelperInstaller: MolePrivilegedHelperInstaller = MolePrivilegedHelperInstaller()
    ) {
        self.apiClient = apiClient
        self.privilegedHelperInstaller = privilegedHelperInstaller
        self.cliPath = apiClient.commandBuilder.executableURL.path
        self.configPath = apiClient.environment["MOLE_CONFIG_DIR"] ?? "~/.config/mole"
        self.logPath = apiClient.environment["MOLE_LOG_DIR"] ?? "~/Library/Logs/mole"
        self.privilegedHelperStatus = privilegedHelperInstaller.status()
    }

    public var healthScore: Int {
        status?.healthScore ?? scoreFromCleanupAndDisk()
    }

    public var diskPressure: Double {
        status?.disks.first(where: { $0.mount == "/" })?.usedPercent
            ?? status?.disks.first?.usedPercent
            ?? optimizePreview?.diskUsedPercent
            ?? 0
    }

    public var recommendedActions: [String] {
        var actions: [String] = []
        if cleanupPreview?.estimatedBytes ?? 0 > 500_000_000 {
            actions.append("Review cleanup preview")
        }
        if diskPressure > 85 {
            actions.append("Scan storage pressure")
        }
        if let alerts = status?.processAlerts, alerts.contains(where: { $0.status == "active" }) {
            actions.append("Inspect process alerts")
        }
        if optimizePreview?.optimizations.isEmpty == false {
            actions.append("Preview optimizations")
        }
        return actions.isEmpty ? ["Run a fresh system care scan"] : actions
    }

    public func loadHome() async {
        isLoading = true
        errorMessage = nil
        sectionErrors[.home] = nil

        var failures: [String] = []
        do {
            status = try await apiClient.status()
        } catch {
            failures.append("Monitor: \(Self.displayMessage(for: error))")
        }
        do {
            optimizePreview = try await apiClient.optimizePreview()
        } catch {
            failures.append("Performance: \(Self.displayMessage(for: error))")
        }

        if failures.isEmpty {
            sectionErrors[.home] = nil
        } else {
            sectionErrors[.home] = failures.joined(separator: "\n")
        }
        isLoading = false
    }

    public func loadStatus() async {
        await runLoadingTask(section: .monitor) {
            status = try await apiClient.status()
        }
    }

    public func loadCleanupPreview() async {
        await runLoadingTask(section: .cleanup) {
            cleanupPreview = try await apiClient.cleanupPreview()
        }
    }

    public func loadExternalCleanupPreview(path: String) async {
        await runLoadingTask(section: .cleanup) {
            externalCleanupPreview = try await apiClient.externalCleanupPreview(path: path)
        }
    }

    public func loadApplications() async {
        await runLoadingTask(section: .applications) {
            applications = try await apiClient.applications().apps
        }
    }

    public func loadStorage(path: String = NSHomeDirectory()) async {
        await runLoadingTask(section: .storage) {
            storageScan = try await apiClient.storageScan(path: path)
        }
    }

    public func executeStorageAction(operation: String, scanPath: String, targets: [String], dryRun: Bool = false) async {
        await runLoadingTask(section: .storage) {
            let planURL = try writeTemporaryPlan(ExecutionPlan(
                confirmed: true,
                dryRun: dryRun,
                targets: targets,
                scanPath: scanPath,
                operation: operation
            ))
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamStorage(planURL: planURL))
        }
    }

    public func loadPurgePreview() async {
        await runLoadingTask(section: .storage) {
            purgePreview = try await apiClient.purgePreview()
        }
    }

    public func loadInstallerPreview() async {
        await runLoadingTask(section: .storage) {
            installerPreview = try await apiClient.installerPreview()
        }
    }

    public func loadOptimizePreview() async {
        await runLoadingTask(section: .performance) {
            optimizePreview = try await apiClient.optimizePreview()
        }
    }

    public func loadSettings() async {
        await runLoadingTask(section: .settings) {
            async let clean = apiClient.whitelist(mode: "clean")
            async let optimize = apiClient.whitelist(mode: "optimize")
            async let paths = apiClient.purgePaths()
            async let touchID = apiClient.touchIDStatus()
            async let completion = apiClient.completionStatus()
            async let launchers = apiClient.launcherStatus()
            async let maintenance = apiClient.maintenanceStatus()

            cleanWhitelist = try await clean
            optimizeWhitelist = try await optimize
            purgePaths = try await paths
            touchIDStatus = try await touchID
            completionStatus = try await completion
            launcherStatus = try await launchers
            maintenanceStatus = try await maintenance
            privilegedHelperStatus = privilegedHelperInstaller.status()
        }
    }

    public func installPrivilegedHelper() async {
        await runLoadingTask(section: .settings) {
            try privilegedHelperInstaller.register()
            privilegedHelperStatus = privilegedHelperInstaller.status()
        }
    }

    public func uninstallPrivilegedHelper() async {
        await runLoadingTask(section: .settings) {
            try privilegedHelperInstaller.unregister()
            privilegedHelperStatus = privilegedHelperInstaller.status()
        }
    }

    public func updatePurgePaths(paths: [String]) async {
        await runLoadingTask(section: .settings) {
            let cleaned = paths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let planURL = try writeTemporaryPlan(ExecutionPlan(confirmed: true, paths: cleaned))
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamPurgePathsUpdate(planURL: planURL))
            purgePaths = try await apiClient.purgePaths()
        }
    }

    public func updateWhitelist(mode: String, patterns: [String]) async {
        await runLoadingTask(section: .settings) {
            let planURL = try writeTemporaryPlan(ExecutionPlan(confirmed: true, patterns: patterns))
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamWhitelistUpdate(mode: mode, planURL: planURL))
            if mode == "optimize" {
                optimizeWhitelist = try await apiClient.whitelist(mode: "optimize")
            } else {
                cleanWhitelist = try await apiClient.whitelist(mode: "clean")
            }
        }
    }

    public func executeTouchID(action: String, dryRun: Bool = false, administrator: Bool = false) async {
        await runLoadingTask(section: .settings) {
            let planURL = try writeTemporaryPlan(ExecutionPlan(confirmed: true, dryRun: dryRun))
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamTouchID(
                action: action,
                planURL: planURL,
                administrator: administrator && !dryRun
            ))
            touchIDStatus = try await apiClient.touchIDStatus()
        }
    }

    public func executeCompletion(dryRun: Bool = false) async {
        await runLoadingTask(section: .settings) {
            let planURL = try writeTemporaryPlan(ExecutionPlan(confirmed: true, dryRun: dryRun))
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamCompletion(planURL: planURL))
            completionStatus = try await apiClient.completionStatus()
        }
    }

    public func executeLaunchers(dryRun: Bool = false) async {
        await runLoadingTask(section: .settings) {
            let planURL = try writeTemporaryPlan(ExecutionPlan(confirmed: true, dryRun: dryRun))
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamLaunchers(planURL: planURL))
            launcherStatus = try await apiClient.launcherStatus()
        }
    }

    public func execute(domain: ExecutionDomain, plan: ExecutionPlan, administrator: Bool = false) async {
        await runLoadingTask(section: section(for: domain)) {
            let planURL = try writeTemporaryPlan(plan)
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamExecute(
                domain: domain,
                planURL: planURL,
                administrator: administrator && !plan.dryRun
            ))
        }
    }

    public func error(for section: MoleSection) -> String? {
        sectionErrors[section] ?? errorMessage
    }

    public func performRecommendedAction(_ action: String) async {
        if action.contains("cleanup") {
            selectedSection = .cleanup
            await loadCleanupPreview()
        } else if action.contains("storage") {
            selectedSection = .storage
            await loadStorage()
        } else if action.contains("process") {
            selectedSection = .monitor
            await loadStatus()
        } else {
            selectedSection = .performance
            await loadOptimizePreview()
        }
    }

    nonisolated public static func transition(from state: PreviewExecutionState, event: ExecutionEvent) -> PreviewExecutionState {
        switch event.event {
        case "started":
            return .running
        case "completed":
            return .completed
        case "failed":
            return .failed(event.message ?? "Execution failed")
        default:
            return state
        }
    }

    private func runLoadingTask(section: MoleSection, _ operation: () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        sectionErrors[section] = nil
        do {
            try await operation()
        } catch {
            let message = Self.displayMessage(for: error)
            errorMessage = message
            sectionErrors[section] = message
            if section == selectedSection {
                executionState = .failed(message)
            }
        }
        isLoading = false
    }

    private func consumeExecutionEvents(_ stream: AsyncThrowingStream<ExecutionEvent, Error>) async throws {
        for try await event in stream {
            executionEvents.append(event)
            executionState = Self.transition(from: executionState, event: event)
        }
        if case .running = executionState {
            executionState = .completed
        }
    }

    private func scoreFromCleanupAndDisk() -> Int {
        var score = 88
        if diskPressure > 90 {
            score -= 18
        } else if diskPressure > 80 {
            score -= 8
        }
        if cleanupPreview?.adminRequired == true {
            score -= 4
        }
        return max(0, min(100, score))
    }

    private func writeTemporaryPlan(_ plan: ExecutionPlan) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mole-plan-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: url, options: .atomic)
        return url
    }

    private func section(for domain: ExecutionDomain) -> MoleSection {
        switch domain {
        case .clean: .cleanup
        case .uninstall: .applications
        case .purge, .installer: .storage
        case .optimize: .performance
        case .update, .remove: .settings
        }
    }

    private static func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

public enum PreviewExecutionState: Equatable {
    case idle
    case previewReady
    case confirming
    case running
    case completed
    case failed(String)
}
