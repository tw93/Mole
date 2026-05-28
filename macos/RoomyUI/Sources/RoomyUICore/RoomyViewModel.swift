import Foundation
import SwiftUI

@MainActor
public final class RoomyViewModel: ObservableObject {
    @Published public var selectedSection: RoomySection = .home
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
    @Published public var maintenanceStatus: RoomyMaintenanceStatus?
    @Published public var privilegedHelperStatus: PrivilegedHelperStatusSnapshot?
    @Published public var fullDiskAccessStatus: FullDiskAccessStatus
    @Published public var permissionOnboardingDismissed: Bool
    @Published public var operationJournalEntries: [OperationJournalEntry] = []
    @Published public var executionEvents: [ExecutionEvent] = []
    @Published public var executionState: PreviewExecutionState = .idle
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var sectionErrors: [RoomySection: String] = [:]
    @Published public var cliPath: String
    @Published public var configPath: String
    @Published public var logPath: String

    public var apiClient: RoomyAPIClient
    public var privilegedHelperInstaller: RoomyPrivilegedHelperInstaller
    private var activeLoadingTaskCount = 0

    public init(
        apiClient: RoomyAPIClient = RoomyAPIClient(),
        privilegedHelperInstaller: RoomyPrivilegedHelperInstaller = RoomyPrivilegedHelperInstaller()
    ) {
        self.apiClient = apiClient
        self.privilegedHelperInstaller = privilegedHelperInstaller
        self.cliPath = apiClient.commandBuilder.executableURL.path
        self.configPath = apiClient.environment["ROOMY_CONFIG_DIR"] ?? "~/.config/roomy"
        self.logPath = apiClient.environment["ROOMY_LOG_DIR"] ?? "~/Library/Logs/roomy"
        self.privilegedHelperStatus = privilegedHelperInstaller.status()
        self.fullDiskAccessStatus = RoomyFullDiskAccessDetector.detect()
        self.permissionOnboardingDismissed = UserDefaults.standard.bool(forKey: Self.permissionOnboardingDismissedKey)
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
        beginLoading()
        defer { endLoading() }
        errorMessage = nil
        sectionErrors[.home] = nil

        var failures: [String] = []
        do {
            status = try await apiClient.status()
        } catch {
            failures.append("Monitor: \(Self.displayMessage(for: error))")
        }

        if failures.isEmpty {
            sectionErrors[.home] = nil
        } else {
            sectionErrors[.home] = failures.joined(separator: "\n")
        }
        loadOperationJournal(limit: 8)
    }

    public func loadStatus() async {
        await runLoadingTask(section: .monitor) {
            status = try await apiClient.status()
        }
    }

    public func refreshFullDiskAccessStatus() {
        fullDiskAccessStatus = RoomyFullDiskAccessDetector.detect()
    }

    public func continueWithLimitedAccess() {
        permissionOnboardingDismissed = true
        UserDefaults.standard.set(true, forKey: Self.permissionOnboardingDismissedKey)
    }

    public func loadOperationJournal(limit: Int = 24) {
        operationJournalEntries = apiClient.operationJournalEntries(limit: limit)
    }

    public func loadCleanupPreview() async {
        await runLoadingTask(section: .cleanup) {
            cleanupPreview = try await apiClient.cleanupPreview()
        }
    }

    public func prepareCleanMyMac(section: RoomySection = .home) async {
        await runLoadingTask(section: section) {
            executionEvents = []
            cleanupPreview = try await apiClient.cleanupPreview()
            executionState = .previewReady
        }
    }

    public func executeCleanMyMac(section: RoomySection = .home) async {
        await runLoadingTask(section: section) {
            let planURL = try writeTemporaryPlan(ExecutionPlan(confirmed: true))
            defer { removeTemporaryPlan(planURL) }
            let useAdministrator = cleanupPreview?.adminRequired == true
                && privilegedHelperStatus?.state == .enabled
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamExecute(
                domain: .clean,
                planURL: planURL,
                administrator: useAdministrator
            ))
            loadOperationJournal()
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
            defer { removeTemporaryPlan(planURL) }
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
            async let clean = captureSettingsValue("Cleanup protection") {
                try await apiClient.whitelist(mode: "clean")
            }
            async let optimize = captureSettingsValue("Performance protection") {
                try await apiClient.whitelist(mode: "optimize")
            }
            async let paths = captureSettingsValue("Project scan paths") {
                try await apiClient.purgePaths()
            }
            async let touchID = captureSettingsValue("Touch ID") {
                try await apiClient.touchIDStatus()
            }
            async let completion = captureSettingsValue("Shell completion") {
                try await apiClient.completionStatus()
            }
            async let launchers = captureSettingsValue("Quick launchers") {
                try await apiClient.launcherStatus()
            }
            async let maintenance = captureSettingsValue("Roomy maintenance") {
                try await apiClient.maintenanceStatus()
            }

            let results = await (
                clean: clean,
                optimize: optimize,
                paths: paths,
                touchID: touchID,
                completion: completion,
                launchers: launchers,
                maintenance: maintenance
            )

            if let value = results.clean.value { cleanWhitelist = value }
            if let value = results.optimize.value { optimizeWhitelist = value }
            if let value = results.paths.value { purgePaths = value }
            if let value = results.touchID.value { touchIDStatus = value }
            if let value = results.completion.value { completionStatus = value }
            if let value = results.launchers.value { launcherStatus = value }
            if let value = results.maintenance.value { maintenanceStatus = value }
            privilegedHelperStatus = privilegedHelperInstaller.status()

            let failures = [
                results.clean.failure,
                results.optimize.failure,
                results.paths.failure,
                results.touchID.failure,
                results.completion.failure,
                results.launchers.failure,
                results.maintenance.failure
            ].compactMap { $0 }
            if !failures.isEmpty {
                throw SettingsLoadError(messages: failures)
            }
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
            defer { removeTemporaryPlan(planURL) }
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamPurgePathsUpdate(planURL: planURL))
            purgePaths = try await apiClient.purgePaths()
        }
    }

    public func updateWhitelist(mode: String, patterns: [String]) async {
        await runLoadingTask(section: .settings) {
            let planURL = try writeTemporaryPlan(ExecutionPlan(confirmed: true, patterns: patterns))
            defer { removeTemporaryPlan(planURL) }
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
            defer { removeTemporaryPlan(planURL) }
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
            defer { removeTemporaryPlan(planURL) }
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamCompletion(planURL: planURL))
            completionStatus = try await apiClient.completionStatus()
        }
    }

    public func executeLaunchers(dryRun: Bool = false) async {
        await runLoadingTask(section: .settings) {
            let planURL = try writeTemporaryPlan(ExecutionPlan(confirmed: true, dryRun: dryRun))
            defer { removeTemporaryPlan(planURL) }
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamLaunchers(planURL: planURL))
            launcherStatus = try await apiClient.launcherStatus()
        }
    }

    public func execute(domain: ExecutionDomain, plan: ExecutionPlan, administrator: Bool = false) async {
        await runLoadingTask(section: section(for: domain)) {
            let planURL = try writeTemporaryPlan(plan)
            defer { removeTemporaryPlan(planURL) }
            executionState = .running
            executionEvents = []
            try await consumeExecutionEvents(apiClient.streamExecute(
                domain: domain,
                planURL: planURL,
                administrator: administrator && !plan.dryRun
            ))
        }
    }

    public func error(for section: RoomySection) -> String? {
        sectionErrors[section]
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
            if let exitCode = event.exitCode, exitCode != 0 {
                return .failed(userFacingMessage(event.message ?? "Execution exited with status \(exitCode)"))
            }
            return .completed
        case "failed":
            return .failed(userFacingMessage(event.message ?? "Execution failed"))
        default:
            return state
        }
    }

    private func runLoadingTask(section: RoomySection, _ operation: () async throws -> Void) async {
        beginLoading()
        defer { endLoading() }
        errorMessage = nil
        sectionErrors[section] = nil
        let enteredWithCommandState = executionState.isCommandActive
        do {
            try await operation()
        } catch {
            let message = Self.displayMessage(for: error)
            errorMessage = message
            sectionErrors[section] = message
            if section == selectedSection || enteredWithCommandState || executionState.isCommandActive {
                executionState = .failed(message)
            }
        }
    }

    private func captureSettingsValue<Value>(
        _ label: String,
        _ operation: () async throws -> Value
    ) async -> SettingsValueResult<Value> {
        do {
            return SettingsValueResult(value: try await operation(), failure: nil)
        } catch {
            return SettingsValueResult(value: nil, failure: "\(label): \(Self.displayMessage(for: error))")
        }
    }

    private func beginLoading() {
        activeLoadingTaskCount += 1
        isLoading = true
    }

    private func endLoading() {
        activeLoadingTaskCount = max(0, activeLoadingTaskCount - 1)
        isLoading = activeLoadingTaskCount > 0
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
        let planDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomyPlans", isDirectory: true)
        try FileManager.default.createDirectory(
            at: planDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: planDirectory.path)

        let url = planDirectory
            .appendingPathComponent("roomy-plan-\(UUID().uuidString)")
            .appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func removeTemporaryPlan(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func section(for domain: ExecutionDomain) -> RoomySection {
        switch domain {
        case .clean: .cleanup
        case .uninstall: .applications
        case .purge, .installer: .storage
        case .optimize: .performance
        case .update, .remove: .settings
        }
    }

    nonisolated public static func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return userFacingMessage(description)
        }
        return userFacingMessage(error.localizedDescription)
    }

    nonisolated public static func userFacingMessage(_ rawMessage: String) -> String {
        let lowercased = rawMessage.lowercased()
        let permissionMarkers = [
            "operation not permitted",
            "permission denied",
            "not authorized",
            "privacy",
            "tcc"
        ]

        if permissionMarkers.contains(where: { lowercased.contains($0) }) {
            return "macOS denied access to part of the scan. Enable Full Disk Access once in System Settings, or choose a narrower folder and try again."
        }

        return rawMessage
    }

    private static let permissionOnboardingDismissedKey = "RoomyUI.permissionOnboardingDismissed"
}

public enum PreviewExecutionState: Equatable {
    case idle
    case previewReady
    case confirming
    case running
    case completed
    case failed(String)

    var isCommandActive: Bool {
        switch self {
        case .previewReady, .confirming, .running:
            true
        case .idle, .completed, .failed:
            false
        }
    }
}

private struct SettingsValueResult<Value> {
    var value: Value?
    var failure: String?
}

private struct SettingsLoadError: LocalizedError {
    var messages: [String]

    var errorDescription: String? {
        messages.joined(separator: "\n")
    }
}
