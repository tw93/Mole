import Foundation
import RoomyUIPrivileged

public enum RoomyEndpoint: Equatable {
    case status
    case cleanupPreview
    case externalCleanupPreview(path: String)
    case applications
    case storageScan(path: String)
    case storageExecute(planURL: URL)
    case optimizePreview
    case purgePreview
    case installerPreview
    case whitelist(mode: String)
    case whitelistUpdate(mode: String, planURL: URL)
    case purgePaths
    case purgePathsUpdate(planURL: URL)
    case maintenanceStatus
    case touchIDStatus
    case touchIDExecute(action: String, planURL: URL)
    case completionStatus
    case completionExecute(planURL: URL)
    case launcherStatus
    case launcherExecute(planURL: URL)
    case execute(domain: ExecutionDomain, planURL: URL)
}

public struct RoomyCommandBuilder: Equatable {
    public var executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func arguments(for endpoint: RoomyEndpoint) -> [String] {
        switch endpoint {
        case .status:
            ["api", "status"]
        case .cleanupPreview:
            ["api", "clean", "preview", "--json"]
        case let .externalCleanupPreview(path):
            ["api", "clean", "preview", "--json", "--external", path]
        case .applications:
            ["api", "apps", "list", "--json"]
        case let .storageScan(path):
            ["api", "storage", "scan", "--path", path]
        case let .storageExecute(planURL):
            ["api", "storage", "execute", "--plan", planURL.path]
        case .optimizePreview:
            ["api", "optimize", "preview"]
        case .purgePreview:
            ["api", "purge", "preview", "--json"]
        case .installerPreview:
            ["api", "installer", "preview", "--json"]
        case let .whitelist(mode):
            ["api", "whitelist", "list", "--mode", mode]
        case let .whitelistUpdate(mode, planURL):
            ["api", "whitelist", "update", "--mode", mode, "--plan", planURL.path]
        case .purgePaths:
            ["api", "purge", "paths", "--json"]
        case let .purgePathsUpdate(planURL):
            ["api", "purge", "paths", "update", "--plan", planURL.path]
        case .maintenanceStatus:
            ["api", "update", "status"]
        case .touchIDStatus:
            ["api", "touchid", "status"]
        case let .touchIDExecute(action, planURL):
            ["api", "touchid", "execute", "--action", action, "--plan", planURL.path]
        case .completionStatus:
            ["api", "completion", "status"]
        case let .completionExecute(planURL):
            ["api", "completion", "execute", "--plan", planURL.path]
        case .launcherStatus:
            ["api", "launchers", "status"]
        case let .launcherExecute(planURL):
            ["api", "launchers", "execute", "--plan", planURL.path]
        case let .execute(domain, planURL):
            ["api", domain.rawValue, "execute", "--plan", planURL.path]
        }
    }
}

public enum RoomyCLIPathResolver {
    public static func resolve(
        environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        bundleExecutableURL: URL? = Bundle.main.executableURL
    ) -> URL {
        if let override = environment["ROOMY_CLI_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        var roots: [URL] = [currentDirectory]
        if let projectRoot = environment["ROOMY_PROJECT_ROOT"], !projectRoot.isEmpty {
            roots.append(URL(fileURLWithPath: projectRoot))
        }
        if
            let markerURL = bundleResourceURL?.appendingPathComponent("roomy-project-root"),
            let marker = try? String(contentsOf: markerURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !marker.isEmpty
        {
            roots.append(URL(fileURLWithPath: marker, isDirectory: true))
        }
        if let executablePath = CommandLine.arguments.first, !executablePath.isEmpty {
            let executableURL = URL(fileURLWithPath: executablePath, relativeTo: currentDirectory)
                .standardizedFileURL
                .deletingLastPathComponent()
            roots.append(executableURL)
        }
        if let bundleExecutable = bundleExecutableURL?.deletingLastPathComponent() {
            roots.append(bundleExecutable.standardizedFileURL)
        }

        var candidates: [URL] = []
        var seenRoots = Set<String>()
        for root in roots {
            var cursor = root
            for _ in 0..<10 {
                let key = cursor.path
                if seenRoots.insert(key).inserted {
                    candidates.append(cursor.appendingPathComponent("roomy"))
                    candidates.append(cursor.appendingPathComponent("mo"))
                }
                cursor.deleteLastPathComponent()
            }
        }

        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return match
        }

        return URL(fileURLWithPath: "/usr/local/bin/roomy")
    }
}

public struct RoomyAPIClient {
    public var commandBuilder: RoomyCommandBuilder
    public var environment: [String: String]
    public var processTimeout: TimeInterval
    public var privilegedRunner: RoomyPrivilegedCommandRunning

    public init(
        executableURL: URL = RoomyCLIPathResolver.resolve(),
        environment: [String: String] = Foundation.ProcessInfo.processInfo.environment,
        processTimeout: TimeInterval? = nil,
        privilegedRunner: RoomyPrivilegedCommandRunning = RoomyPrivilegedHelperClient()
    ) {
        self.commandBuilder = RoomyCommandBuilder(executableURL: executableURL)
        self.environment = Self.preparedEnvironment(environment, executableURL: executableURL)
        self.processTimeout = processTimeout ?? Self.processTimeout(from: environment)
        self.privilegedRunner = privilegedRunner
    }

    public func status() async throws -> StatusSnapshot {
        try await runJSON(.status)
    }

    public func cleanupPreview() async throws -> CleanupPreview {
        try await runJSON(.cleanupPreview)
    }

    public func externalCleanupPreview(path: String) async throws -> CleanupPreview {
        try await runJSON(.externalCleanupPreview(path: path))
    }

    public func applications() async throws -> ApplicationListResponse {
        try await runJSON(.applications)
    }

    public func storageScan(path: String) async throws -> StorageScan {
        try await runJSON(.storageScan(path: path))
    }

    public func executeStorage(planURL: URL) async throws -> [ExecutionEvent] {
        let data = try await runProcess(.storageExecute(planURL: planURL))
        return Self.decodeEvents(from: data)
    }

    public func streamStorage(planURL: URL) -> AsyncThrowingStream<ExecutionEvent, Error> {
        streamEvents(.storageExecute(planURL: planURL))
    }

    public func optimizePreview() async throws -> OptimizePreview {
        try await runJSON(.optimizePreview)
    }

    public func purgePreview() async throws -> PurgePreview {
        try await runJSON(.purgePreview)
    }

    public func installerPreview() async throws -> InstallerPreview {
        try await runJSON(.installerPreview)
    }

    public func whitelist(mode: String) async throws -> WhitelistResponse {
        try await runJSON(.whitelist(mode: mode))
    }

    public func updateWhitelist(mode: String, planURL: URL) async throws -> [ExecutionEvent] {
        let data = try await runProcess(.whitelistUpdate(mode: mode, planURL: planURL))
        return Self.decodeEvents(from: data)
    }

    public func streamWhitelistUpdate(mode: String, planURL: URL) -> AsyncThrowingStream<ExecutionEvent, Error> {
        streamEvents(.whitelistUpdate(mode: mode, planURL: planURL))
    }

    public func purgePaths() async throws -> PurgePathsResponse {
        try await runJSON(.purgePaths)
    }

    public func updatePurgePaths(planURL: URL) async throws -> [ExecutionEvent] {
        let data = try await runProcess(.purgePathsUpdate(planURL: planURL))
        return Self.decodeEvents(from: data)
    }

    public func streamPurgePathsUpdate(planURL: URL) -> AsyncThrowingStream<ExecutionEvent, Error> {
        streamEvents(.purgePathsUpdate(planURL: planURL))
    }

    public func maintenanceStatus() async throws -> RoomyMaintenanceStatus {
        try await runJSON(.maintenanceStatus)
    }

    public func touchIDStatus() async throws -> TouchIDStatus {
        try await runJSON(.touchIDStatus)
    }

    public func completionStatus() async throws -> CompletionStatus {
        try await runJSON(.completionStatus)
    }

    public func launcherStatus() async throws -> LauncherStatus {
        try await runJSON(.launcherStatus)
    }

    public func operationJournalEntries(limit: Int = 24) -> [OperationJournalEntry] {
        Self.readOperationJournal(url: operationJournalURL, limit: limit)
    }

    public static func readOperationJournal(url: URL, limit: Int = 24) -> [OperationJournalEntry] {
        guard limit > 0, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }

        let lines = text
            .split(separator: "\n")
            .suffix(limit)

        return Array(lines
            .enumerated()
            .compactMap { offset, line in
                guard let entry = try? decoder.decode(OperationJournalEntry.self, from: Data(line.utf8)) else {
                    return nil
                }
                return entry.sequenced(offset)
            }
            .reversed())
    }

    public func executeTouchID(action: String, planURL: URL, administrator: Bool) async throws -> [ExecutionEvent] {
        let endpoint = RoomyEndpoint.touchIDExecute(action: action, planURL: planURL)
        let data = try await (administrator ? runAdministratorProcess(endpoint) : runProcess(endpoint))
        return Self.decodeEvents(from: data)
    }

    public func streamTouchID(action: String, planURL: URL, administrator: Bool) -> AsyncThrowingStream<ExecutionEvent, Error> {
        streamEvents(.touchIDExecute(action: action, planURL: planURL), administrator: administrator)
    }

    public func executeCompletion(planURL: URL) async throws -> [ExecutionEvent] {
        let data = try await runProcess(.completionExecute(planURL: planURL))
        return Self.decodeEvents(from: data)
    }

    public func streamCompletion(planURL: URL) -> AsyncThrowingStream<ExecutionEvent, Error> {
        streamEvents(.completionExecute(planURL: planURL))
    }

    public func executeLaunchers(planURL: URL) async throws -> [ExecutionEvent] {
        let data = try await runProcess(.launcherExecute(planURL: planURL))
        return Self.decodeEvents(from: data)
    }

    public func streamLaunchers(planURL: URL) -> AsyncThrowingStream<ExecutionEvent, Error> {
        streamEvents(.launcherExecute(planURL: planURL))
    }

    public func execute(domain: ExecutionDomain, planURL: URL, administrator: Bool = false) async throws -> [ExecutionEvent] {
        do {
            let endpoint = RoomyEndpoint.execute(domain: domain, planURL: planURL)
            let data = try await (administrator ? runAdministratorProcess(endpoint) : runProcess(endpoint))
            return Self.decodeEvents(from: data)
        } catch let RoomyAPIError.processFailed(_, message) {
            let events = Self.decodeEvents(from: Data(message.utf8))
            if !events.isEmpty {
                return events
            }
            throw RoomyAPIError.processFailed(status: 1, message: message)
        }
    }

    public func streamExecute(domain: ExecutionDomain, planURL: URL, administrator: Bool = false) -> AsyncThrowingStream<ExecutionEvent, Error> {
        streamEvents(.execute(domain: domain, planURL: planURL), administrator: administrator)
    }

    private static func decodeEvents(from data: Data) -> [ExecutionEvent] {
        data
            .split(separator: UInt8(ascii: "\n"))
            .compactMap { line in
                try? Self.decoder.decode(ExecutionEvent.self, from: Data(line))
            }
    }

    public func runJSON<T: Decodable>(_ endpoint: RoomyEndpoint) async throws -> T {
        let data = try await runProcess(endpoint)
        return try Self.decoder.decode(T.self, from: data)
    }

    public func runProcess(_ endpoint: RoomyEndpoint) async throws -> Data {
        let executableURL = commandBuilder.executableURL
        let arguments = commandBuilder.arguments(for: endpoint)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        return try await runConfiguredProcess(process, commandDescription: commandDescription(for: executableURL, arguments: arguments)) { status, data, errorData in
            let message = Self.errorMessage(from: errorData.isEmpty ? data : errorData)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RoomyAPIError.processFailed(
                status: status,
                message: message ?? "roomy exited with status \(status)"
            )
        }
    }

    public func runAdministratorProcess(_ endpoint: RoomyEndpoint) async throws -> Data {
        let command = try privilegedCommand(for: endpoint)
        let result = try await privilegedRunner.run(command: command)
        if result.exitCode == 0 {
            return result.standardOutput
        }

        let message = Self.errorMessage(from: result.standardError.isEmpty ? result.standardOutput : result.standardError)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw RoomyAPIError.processFailed(
            status: result.exitCode,
            message: message ?? "Privileged Roomy command exited with status \(result.exitCode)"
        )
    }

    public func runAppleScriptAdministratorProcess(_ endpoint: RoomyEndpoint) async throws -> Data {
        let command = shellCommand(for: endpoint, includeEnvironment: true) + " 2>&1"
        let script = "do shell script \(Self.appleScriptString(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        return try await runConfiguredProcess(process, commandDescription: "osascript administrator command") { status, data, errorData in
            let message = String(data: errorData.isEmpty ? data : errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RoomyAPIError.processFailed(
                status: status,
                message: message ?? "Administrator command failed"
            )
        }
    }

    public func streamEvents(_ endpoint: RoomyEndpoint, administrator: Bool = false) -> AsyncThrowingStream<ExecutionEvent, Error> {
        if administrator {
            return streamAdministratorEvents(endpoint)
        }

        return AsyncThrowingStream { continuation in
            let process = Process()
            let commandDescription: String

            let executableURL = commandBuilder.executableURL
            let arguments = commandBuilder.arguments(for: endpoint)
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            commandDescription = self.commandDescription(for: executableURL, arguments: arguments)

            let output = Pipe()
            let error = Pipe()
            let buffer = ProcessEventLineBuffer(decoder: Self.decoder)
            let state = ProcessEventStreamState()
            let timeout = processTimeout

            process.standardOutput = output
            process.standardError = error

            let consumeOutput: (Data) -> Void = { data in
                buffer.append(data) { event in
                    state.markEvent(event)
                    continuation.yield(event)
                }
            }

            let cleanup: () -> Void = {
                output.fileHandleForReading.readabilityHandler = nil
                error.fileHandleForReading.readabilityHandler = nil
            }

            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    consumeOutput(data)
                }
            }

            var errorData = Data()
            let errorLock = NSLock()
            error.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    errorLock.lock()
                    errorData.append(data)
                    errorLock.unlock()
                }
            }

            let timeoutWork = DispatchWorkItem {
                cleanup()
                if process.isRunning {
                    process.terminate()
                }
                state.finish(continuation, error: RoomyAPIError.timedOut(command: commandDescription, seconds: timeout))
            }

            process.terminationHandler = { terminatedProcess in
                cleanup()
                consumeOutput(output.fileHandleForReading.readDataToEndOfFile())
                errorLock.lock()
                errorData.append(error.fileHandleForReading.readDataToEndOfFile())
                let capturedError = errorData
                errorLock.unlock()
                buffer.flush { event in
                    state.markEvent(event)
                    continuation.yield(event)
                }
                timeoutWork.cancel()

                if terminatedProcess.terminationStatus == 0 || state.hasTerminalEvent {
                    state.finish(continuation)
                    return
                }

                let message = Self.errorMessage(from: capturedError)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                state.finish(
                    continuation,
                    error: RoomyAPIError.processFailed(
                        status: terminatedProcess.terminationStatus,
                        message: message ?? "roomy exited with status \(terminatedProcess.terminationStatus)"
                    )
                )
            }

            continuation.onTermination = { _ in
                cleanup()
                timeoutWork.cancel()
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
                if timeout > 0 {
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                }
            } catch {
                cleanup()
                timeoutWork.cancel()
                state.finish(continuation, error: error)
            }
        }
    }

    private func streamAdministratorEvents(_ endpoint: RoomyEndpoint) -> AsyncThrowingStream<ExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let command = try privilegedCommand(for: endpoint)
                    let result = try await privilegedRunner.run(command: command)
                    let events = Self.decodeEvents(from: result.standardOutput)
                    let hasTerminalEvent = events.contains { $0.event == "completed" || $0.event == "failed" }

                    for event in events {
                        continuation.yield(event)
                    }

                    if result.exitCode == 0 || hasTerminalEvent {
                        continuation.finish()
                        return
                    }

                    let message = Self.errorMessage(from: result.standardError.isEmpty ? result.standardOutput : result.standardError)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(throwing: RoomyAPIError.processFailed(
                        status: result.exitCode,
                        message: message ?? "Privileged Roomy command exited with status \(result.exitCode)"
                    ))
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runConfiguredProcess(
        _ process: Process,
        commandDescription: String,
        failure: @escaping (Int32, Data, Data) -> RoomyAPIError
    ) async throws -> Data {
        let output = Pipe()
        let error = Pipe()
        let state = ProcessCaptureState()
        let timeout = processTimeout

        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                state.appendOutput(data)
            }
        }

        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                state.appendError(data)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cleanup: () -> Void = {
                    output.fileHandleForReading.readabilityHandler = nil
                    error.fileHandleForReading.readabilityHandler = nil
                }

                let timeoutWork = DispatchWorkItem {
                    cleanup()
                    if process.isRunning {
                        process.terminate()
                    }
                    state.finish(.failure(RoomyAPIError.timedOut(command: commandDescription, seconds: timeout)), continuation: continuation)
                }

                process.terminationHandler = { terminatedProcess in
                    cleanup()
                    state.appendOutput(output.fileHandleForReading.readDataToEndOfFile())
                    state.appendError(error.fileHandleForReading.readDataToEndOfFile())
                    timeoutWork.cancel()

                    let captured = state.snapshot()
                    if terminatedProcess.terminationStatus == 0 {
                        state.finish(.success(captured.output), continuation: continuation)
                    } else {
                        state.finish(
                            .failure(failure(terminatedProcess.terminationStatus, captured.output, captured.error)),
                            continuation: continuation
                        )
                    }
                }

                do {
                    try process.run()
                    if timeout > 0 {
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                    }
                } catch {
                    cleanup()
                    timeoutWork.cancel()
                    state.finish(.failure(error), continuation: continuation)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(value)"
            )
        }
        return decoder
    }

    private static func preparedEnvironment(_ environment: [String: String], executableURL: URL) -> [String: String] {
        var prepared = environment
        let projectRoot = executableURL.deletingLastPathComponent()
        let apiScript = projectRoot.appendingPathComponent("bin/api.sh")

        guard FileManager.default.fileExists(atPath: apiScript.path) else {
            return prepared
        }

        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let stateRoot = homeURL
            .appendingPathComponent("Library/Application Support/Roomy/UI", isDirectory: true)
        let logRoot = homeURL
            .appendingPathComponent("Library/Logs/Roomy/UI", isDirectory: true)
        let cacheRoot = homeURL
            .appendingPathComponent("Library/Caches/Roomy/UI", isDirectory: true)
        let configDir = stateRoot.appendingPathComponent("config", isDirectory: true)
        let logDir = logRoot
        let cacheDir = cacheRoot

        prepared["HOME"] = homeURL.path
        prepared["ROOMY_CONFIG_DIR"] = configDir.path
        prepared["ROOMY_LOG_DIR"] = logDir.path
        prepared["ROOMY_CACHE_DIR"] = cacheDir.path
        prepared["ROOMY_DELETE_LOG"] = logDir.appendingPathComponent("deletions.log").path
        prepared["TERM"] = prepared["TERM"] ?? "dumb"

        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        return prepared
    }

    private static func processTimeout(from environment: [String: String]) -> TimeInterval {
        guard
            let rawValue = environment["ROOMY_UI_PROCESS_TIMEOUT"],
            let value = TimeInterval(rawValue),
            value >= 0
        else {
            return 300
        }
        return value
    }

    private static func errorMessage(from data: Data) -> String? {
        if let envelope = try? decoder.decode(RoomyAPIErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        return String(data: data, encoding: .utf8)
    }

    private func shellCommand(for endpoint: RoomyEndpoint, includeEnvironment: Bool) -> String {
        var parts: [String] = []
        if includeEnvironment {
            for key in ["HOME", "PATH", "SHELL", "ROOMY_CONFIG_DIR", "ROOMY_LOG_DIR", "ROOMY_CACHE_DIR", "ROOMY_DELETE_LOG", "TERM"] {
                if let value = environment[key] {
                    parts.append("\(key)=\(Self.shellQuoted(value))")
                }
            }
        }
        parts.append(Self.shellQuoted(commandBuilder.executableURL.path))
        parts.append(contentsOf: commandBuilder.arguments(for: endpoint).map(Self.shellQuoted))
        return parts.joined(separator: " ")
    }

    private func commandDescription(for executableURL: URL, arguments: [String]) -> String {
        ([executableURL.lastPathComponent] + arguments).joined(separator: " ")
    }

    private var operationJournalURL: URL {
        if let override = environment["ROOMY_OPERATION_JOURNAL_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let logDir = environment["ROOMY_LOG_DIR"], !logDir.isEmpty {
            return URL(fileURLWithPath: logDir, isDirectory: true)
                .appendingPathComponent("operation_journal.jsonl")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Roomy/UI", isDirectory: true)
            .appendingPathComponent("operation_journal.jsonl")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func privilegedCommand(for endpoint: RoomyEndpoint) throws -> PrivilegedCommand {
        try PrivilegedCommandPolicy.command(
            executablePath: commandBuilder.executableURL.path,
            arguments: commandBuilder.arguments(for: endpoint),
            environment: environment,
            timeoutSeconds: processTimeout
        )
    }
}

public enum RoomyAPIError: LocalizedError, Equatable {
    case processFailed(status: Int32, message: String)
    case timedOut(command: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case let .processFailed(status, message):
            "roomy failed with status \(status): \(message)"
        case let .timedOut(command, seconds):
            "\(command) timed out after \(Int(seconds.rounded())) seconds"
        }
    }
}

private final class ProcessCaptureState {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    private var finished = false

    func appendOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        output.append(data)
        lock.unlock()
    }

    func appendError(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        error.append(data)
        lock.unlock()
    }

    func snapshot() -> (output: Data, error: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (output, error)
    }

    func finish(_ result: Result<Data, Error>, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        continuation.resume(with: result)
    }
}

private final class ProcessEventLineBuffer {
    private let lock = NSLock()
    private var buffer = Data()
    private let decoder: JSONDecoder

    init(decoder: JSONDecoder) {
        self.decoder = decoder
    }

    func append(_ data: Data, yield: (ExecutionEvent) -> Void) {
        guard !data.isEmpty else { return }
        let events: [ExecutionEvent]
        lock.lock()
        buffer.append(data)
        events = extractEventsLocked(flush: false)
        lock.unlock()
        events.forEach(yield)
    }

    func flush(yield: (ExecutionEvent) -> Void) {
        let events: [ExecutionEvent]
        lock.lock()
        events = extractEventsLocked(flush: true)
        lock.unlock()
        events.forEach(yield)
    }

    private func extractEventsLocked(flush: Bool) -> [ExecutionEvent] {
        var events: [ExecutionEvent] = []

        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let event = try? decoder.decode(ExecutionEvent.self, from: Data(line)) {
                events.append(event)
            }
        }

        if flush, !buffer.isEmpty {
            if let event = try? decoder.decode(ExecutionEvent.self, from: buffer) {
                events.append(event)
            }
            buffer.removeAll()
        }

        return events
    }
}

private final class ProcessEventStreamState {
    private let lock = NSLock()
    private var finished = false
    private var eventCount = 0
    private var terminalEventSeen = false

    var hasTerminalEvent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminalEventSeen
    }

    func markEvent(_ event: ExecutionEvent) {
        lock.lock()
        eventCount += 1
        if event.event == "completed" || event.event == "failed" {
            terminalEventSeen = true
        }
        lock.unlock()
    }

    func finish(_ continuation: AsyncThrowingStream<ExecutionEvent, Error>.Continuation, error: Error? = nil) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}

private struct RoomyAPIErrorEnvelope: Decodable {
    var error: RoomyAPIErrorBody
}

private struct RoomyAPIErrorBody: Decodable {
    var message: String
}

public enum Formatters {
    public static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    public static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    public static func cleanupBytes(_ value: Int64) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.2fGB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fMB", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return "\(Int((Double(value) / 1_000).rounded()))KB"
        }
        return "\(value)B"
    }
}
