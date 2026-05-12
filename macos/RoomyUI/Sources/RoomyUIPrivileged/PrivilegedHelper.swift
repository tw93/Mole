import Foundation

public enum RoomyPrivilegedHelperConstants {
    public static let machServiceName = "dev.roomy.native-ui.privileged-helper"
    public static let daemonPlistName = "dev.roomy.native-ui.privileged-helper.plist"
    public static let helperExecutableName = "RoomyPrivilegedHelper"
    public static let appBundleIdentifier = "dev.roomy.native-ui"
    public static let protocolVersion = "1"
}

@objc(RoomyPrivilegedHelperProtocol)
public protocol RoomyPrivilegedHelperProtocol: NSObjectProtocol {
    func helperVersion(withReply reply: @escaping (NSString) -> Void)
    func runCommand(_ request: NSDictionary, withReply reply: @escaping (NSDictionary) -> Void)
}

public struct PrivilegedCommand: Equatable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]
    public var timeoutSeconds: TimeInterval

    public init(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }

    public var dictionaryRepresentation: NSDictionary {
        [
            "executable_path": executablePath,
            "arguments": arguments,
            "environment": environment,
            "timeout_seconds": timeoutSeconds
        ] as NSDictionary
    }

    public static func from(dictionary: NSDictionary) throws -> PrivilegedCommand {
        guard let executablePath = dictionary["executable_path"] as? String else {
            throw PrivilegedCommandPolicyError.invalidRequest("Missing executable path")
        }
        guard let arguments = dictionary["arguments"] as? [String] else {
            throw PrivilegedCommandPolicyError.invalidRequest("Missing arguments")
        }

        let rawEnvironment = dictionary["environment"] as? [String: String] ?? [:]
        let timeoutSeconds = (dictionary["timeout_seconds"] as? NSNumber)?.doubleValue ?? 300

        let command = PrivilegedCommand(
            executablePath: executablePath,
            arguments: arguments,
            environment: PrivilegedCommandPolicy.filteredEnvironment(rawEnvironment),
            timeoutSeconds: timeoutSeconds
        )
        try PrivilegedCommandPolicy.validate(command)
        return command
    }
}

public struct PrivilegedCommandResult: Equatable {
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: Data

    public init(exitCode: Int32, standardOutput: Data, standardError: Data) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var dictionaryRepresentation: NSDictionary {
        [
            "exit_code": NSNumber(value: exitCode),
            "stdout": standardOutput as NSData,
            "stderr": standardError as NSData
        ] as NSDictionary
    }

    public static func from(dictionary: NSDictionary) throws -> PrivilegedCommandResult {
        guard let exitCode = dictionary["exit_code"] as? NSNumber else {
            throw PrivilegedCommandPolicyError.invalidResponse("Missing exit code")
        }
        let stdout = (dictionary["stdout"] as? Data)
            ?? (dictionary["stdout"] as? NSData).map { Data(referencing: $0) }
            ?? Data()
        let stderr = (dictionary["stderr"] as? Data)
            ?? (dictionary["stderr"] as? NSData).map { Data(referencing: $0) }
            ?? Data()
        return PrivilegedCommandResult(
            exitCode: exitCode.int32Value,
            standardOutput: stdout,
            standardError: stderr
        )
    }
}

public enum PrivilegedCommandPolicyError: LocalizedError, Equatable {
    case invalidRequest(String)
    case invalidResponse(String)
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message), let .invalidResponse(message), let .refused(message):
            message
        }
    }
}

public enum PrivilegedCommandPolicy {
    public static let maxPlanBytes = 1_048_576
    public static let maxTimeoutSeconds: TimeInterval = 3600
    public static let safePath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static let allowedExecuteDomains: Set<String> = [
        "clean",
        "uninstall",
        "optimize",
        "update",
        "remove"
    ]

    public static let allowedEnvironmentKeys: Set<String> = [
        "HOME",
        "SHELL",
        "USER",
        "LOGNAME",
        "ROOMY_CONFIG_DIR",
        "ROOMY_LOG_DIR",
        "ROOMY_CACHE_DIR",
        "ROOMY_DELETE_LOG",
        "TERM"
    ]

    public static func command(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeoutSeconds: TimeInterval
    ) throws -> PrivilegedCommand {
        let command = PrivilegedCommand(
            executablePath: executablePath,
            arguments: arguments,
            environment: filteredEnvironment(environment),
            timeoutSeconds: timeoutSeconds
        )
        try validate(command)
        return command
    }

    public static func validate(_ command: PrivilegedCommand) throws {
        guard command.executablePath.hasPrefix("/") else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper requires an absolute executable path")
        }
        guard !containsTraversal(command.executablePath) else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused executable path traversal")
        }
        let executableName = URL(fileURLWithPath: command.executablePath).lastPathComponent
        guard executableName == "roomy" || executableName == "mo" else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper only runs Roomy CLI entrypoints")
        }
        guard command.timeoutSeconds >= 0 else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused a negative timeout")
        }
        guard command.timeoutSeconds <= maxTimeoutSeconds else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused an excessive timeout")
        }

        try validateArguments(command.arguments)
    }

    public static func filteredEnvironment(_ environment: [String: String]) -> [String: String] {
        var filtered: [String: String] = [:]
        for key in allowedEnvironmentKeys {
            guard let value = environment[key], !containsControlCharacters(key), !containsControlCharacters(value) else {
                continue
            }
            filtered[key] = value
        }
        filtered["PATH"] = safePath
        filtered["TERM"] = filtered["TERM"] ?? "dumb"
        return filtered
    }

    private static func validateArguments(_ arguments: [String]) throws {
        guard arguments.count >= 5, arguments[0] == "api" else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper only runs Roomy API execute commands")
        }

        if arguments[1] == "touchid" {
            try validateTouchIDArguments(arguments)
            return
        }

        let domain = arguments[1]
        guard allowedExecuteDomains.contains(domain) else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused unsupported domain: \(domain)")
        }
        guard arguments.count == 5, arguments[2] == "execute", arguments[3] == "--plan" else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused non-execute Roomy API command")
        }
        try validatePlanPath(arguments[4])
    }

    private static func validateTouchIDArguments(_ arguments: [String]) throws {
        guard arguments.count == 7,
              arguments[2] == "execute",
              arguments[3] == "--action",
              (arguments[4] == "enable" || arguments[4] == "disable"),
              arguments[5] == "--plan"
        else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused unsupported Touch ID command")
        }
        try validatePlanPath(arguments[6])
    }

    private static func validatePlanPath(_ path: String) throws {
        guard path.hasPrefix("/") else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper requires an absolute plan path")
        }
        guard !containsTraversal(path) else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused plan path traversal")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper plan file does not exist")
        }

        let url = URL(fileURLWithPath: path)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw PrivilegedCommandPolicyError.refused("Privileged helper could not inspect plan file")
        }
        guard values.isSymbolicLink != true else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused symlinked plan file")
        }
        guard values.isRegularFile == true else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper requires a regular plan file")
        }
        guard (values.fileSize ?? 0) <= maxPlanBytes else {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused oversized plan file")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw PrivilegedCommandPolicyError.refused("Privileged helper could not read plan file")
        }
        do {
            let value = try JSONSerialization.jsonObject(with: data)
            guard let object = value as? [String: Any] else {
                throw PrivilegedCommandPolicyError.refused("Privileged helper requires a JSON object plan")
            }
            guard object["confirmed"] as? Bool == true else {
                throw PrivilegedCommandPolicyError.refused("Privileged helper requires confirmed plan files")
            }
        } catch let policyError as PrivilegedCommandPolicyError {
            throw policyError
        } catch {
            throw PrivilegedCommandPolicyError.refused("Privileged helper refused invalid JSON plan")
        }
    }

    private static func containsTraversal(_ value: String) -> Bool {
        value == ".." || value.contains("/../") || value.hasSuffix("/..") || value.hasPrefix("../")
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}
