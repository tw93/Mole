import Darwin
import Foundation
import RoomyUIPrivileged
import Security

final class RoomyPrivilegedHelperService: NSObject, RoomyPrivilegedHelperProtocol {
    func helperVersion(withReply reply: @escaping (NSString) -> Void) {
        reply(RoomyPrivilegedHelperConstants.protocolVersion as NSString)
    }

    func runCommand(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void) {
        do {
            let command = try PrivilegedCommand.from(dictionary: request)
            try RuntimeCommandPolicy.validateExecutable(command.executablePath)
            let preparedCommand = try RuntimeCommandPolicy.copyPlanToPrivateFile(command)
            defer {
                if let copiedPlanURL = preparedCommand.copiedPlanURL {
                    try? FileManager.default.removeItem(at: copiedPlanURL)
                }
            }
            let result = PrivilegedCommandExecutor.run(preparedCommand.command)
            reply(result.dictionaryRepresentation)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let result = PrivilegedCommandResult(
                exitCode: 126,
                standardOutput: Data(),
                standardError: Data(message.utf8)
            )
            reply(result.dictionaryRepresentation)
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = RoomyPrivilegedHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ClientVerifier.isAuthorized(connection) else {
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: RoomyPrivilegedHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

enum ClientVerifier {
    static func isAuthorized(_ connection: NSXPCConnection) -> Bool {
        guard clientExecutablePath(connection.processIdentifier) == expectedClientExecutablePath() else {
            return false
        }

        var code: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary

        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code
        else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return false
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        else {
            return false
        }

        return identifier == RoomyPrivilegedHelperConstants.appBundleIdentifier
    }

    private static func clientExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else {
            return nil
        }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    private static func expectedClientExecutablePath() -> String? {
        guard let contentsURL = BundleLayout.appContentsURL(fromExecutablePath: BundleLayout.currentExecutablePath()) else {
            return nil
        }
        return contentsURL
            .appendingPathComponent("MacOS/RoomyUI")
            .resolvingSymlinksInPath()
            .path
    }
}

enum RuntimeCommandPolicy {
    struct PreparedCommand {
        var command: PrivilegedCommand
        var copiedPlanURL: URL?
    }

    static func validateExecutable(_ executablePath: String) throws {
        let allowedPaths = allowedCLIPaths()
        guard allowedPaths.contains(executablePath) else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused unbundled Roomy CLI path")
        }
        try validateAppBundleSignature()
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper Roomy CLI path is not executable")
        }
    }

    static func copyPlanToPrivateFile(_ command: PrivilegedCommand) throws -> PreparedCommand {
        guard let planFlagIndex = command.arguments.lastIndex(of: "--plan") else {
            return PreparedCommand(command: command, copiedPlanURL: nil)
        }
        let planIndex = command.arguments.index(after: planFlagIndex)
        guard command.arguments.indices.contains(planIndex) else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper could not locate plan argument")
        }

        let data = try readRegularFileNoFollow(command.arguments[planIndex])
        let copiedURL = try writePrivatePlanCopy(data)

        var arguments = command.arguments
        arguments[planIndex] = copiedURL.path
        let copiedCommand = PrivilegedCommand(
            executablePath: command.executablePath,
            arguments: arguments,
            environment: command.environment,
            timeoutSeconds: command.timeoutSeconds
        )
        try PrivilegedCommandPolicy.validate(copiedCommand)
        return PreparedCommand(command: copiedCommand, copiedPlanURL: copiedURL)
    }

    private static func allowedCLIPaths() -> Set<String> {
        var paths = Set<String>()
        if let contentsURL = BundleLayout.appContentsURL(fromExecutablePath: BundleLayout.currentExecutablePath()) {
            let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
            let cliURL = resourcesURL.appendingPathComponent("RoomyCLI", isDirectory: true)

            paths.insert(contentsURL.appendingPathComponent("MacOS/roomy").path)
            paths.insert(contentsURL.appendingPathComponent("MacOS/mo").path)
            paths.insert(resourcesURL.appendingPathComponent("roomy").path)
            paths.insert(resourcesURL.appendingPathComponent("mo").path)
            paths.insert(cliURL.appendingPathComponent("roomy").path)
            paths.insert(cliURL.appendingPathComponent("mo").path)
        }

        return paths
    }

    private static func validateAppBundleSignature() throws {
        guard let contentsURL = BundleLayout.appContentsURL(fromExecutablePath: BundleLayout.currentExecutablePath()) else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper could not locate app bundle")
        }
        let appURL = contentsURL.deletingLastPathComponent()

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(), nil) == errSecSuccess
        else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused app bundle with invalid signature")
        }
    }

    private static func readRegularFileNoFollow(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper could not safely open plan file")
        }
        defer { close(fd) }

        var statInfo = stat()
        guard fstat(fd, &statInfo) == 0, (statInfo.st_mode & S_IFMT) == S_IFREG else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper requires a regular plan file")
        }
        guard statInfo.st_size <= PrivilegedCommandPolicy.maxPlanBytes else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused oversized plan file")
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw PrivilegedCommandPolicyError.refused("Privileged helper could not read plan file")
        }
    }

    private static func writePrivatePlanCopy(_ data: Data) throws -> URL {
        var template = Array("/private/tmp/roomy-helper-plan.XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { pointer in
            mkstemp(pointer.baseAddress)
        }
        guard fd >= 0 else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper could not create private plan file")
        }
        defer { close(fd) }
        let path = String(cString: template)

        do {
            guard fchmod(fd, 0o600) == 0 else {
                throw PrivilegedCommandPolicyError.refused("Privileged helper could not secure private plan file")
            }

            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else {
                    throw PrivilegedCommandPolicyError.refused("Privileged helper refused empty plan file")
                }

                var remaining = data.count
                var offset = 0
                while remaining > 0 {
                    let written = write(fd, baseAddress.advanced(by: offset), remaining)
                    guard written > 0 else {
                        throw PrivilegedCommandPolicyError.refused("Privileged helper could not write private plan file")
                    }
                    remaining -= written
                    offset += written
                }
            }
        } catch {
            unlink(path)
            throw error
        }

        return URL(fileURLWithPath: path)
    }
}

enum BundleLayout {
    static func appContentsURL(fromExecutablePath path: String) -> URL? {
        let executableURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var cursor = executableURL.deletingLastPathComponent()
        for _ in 0..<8 {
            if cursor.lastPathComponent == "Contents" {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                return nil
            }
            cursor = parent
        }
        return nil
    }

    static func currentExecutablePath() -> String {
        var size = UInt32(0)
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size)
        }
        if result == 0 {
            return String(cString: buffer)
        }
        return CommandLine.arguments.first ?? ""
    }
}

enum PrivilegedCommandExecutor {
    static func run(_ command: PrivilegedCommand) -> PrivilegedCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.environment = command.environment

        let output = Pipe()
        let errorPipe = Pipe()
        let capture = PipeCapture()

        process.standardOutput = output
        process.standardError = errorPipe

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                capture.appendOutput(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                capture.appendError(data)
            }
        }

        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        do {
            try process.run()
        } catch {
            cleanup(output: output, error: errorPipe)
            return PrivilegedCommandResult(
                exitCode: 127,
                standardOutput: Data(),
                standardError: Data(error.localizedDescription.utf8)
            )
        }

        let timedOut: Bool
        if command.timeoutSeconds > 0 {
            let deadline = DispatchTime.now() + .milliseconds(Int(command.timeoutSeconds * 1000))
            timedOut = termination.wait(timeout: deadline) == .timedOut
        } else {
            termination.wait()
            timedOut = false
        }

        if timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                termination.wait()
            }
        }

        cleanup(output: output, error: errorPipe)
        capture.appendOutput(output.fileHandleForReading.readDataToEndOfFile())
        capture.appendError(errorPipe.fileHandleForReading.readDataToEndOfFile())

        let snapshot = capture.snapshot()
        if timedOut {
            var stderr = snapshot.error
            stderr.append(Data("Command timed out after \(Int(command.timeoutSeconds)) seconds".utf8))
            return PrivilegedCommandResult(
                exitCode: 124,
                standardOutput: snapshot.output,
                standardError: stderr
            )
        }

        return PrivilegedCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: snapshot.output,
            standardError: snapshot.error
        )
    }

    private static func cleanup(output: Pipe, error: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
    }
}

final class PipeCapture {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    func appendOutput(_ data: Data) {
        lock.lock()
        output.append(data)
        lock.unlock()
    }

    func appendError(_ data: Data) {
        lock.lock()
        error.append(data)
        lock.unlock()
    }

    func snapshot() -> (output: Data, error: Data) {
        lock.lock()
        defer { lock.unlock() }
        return (output, error)
    }
}

let listener = NSXPCListener(machServiceName: RoomyPrivilegedHelperConstants.machServiceName)
let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
