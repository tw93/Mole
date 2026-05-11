import Foundation
import MoleUIPrivileged
import ServiceManagement

public enum PrivilegedHelperState: String, Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case unavailable
    case unknown
}

public struct PrivilegedHelperStatusSnapshot: Equatable {
    public var label: String
    public var plistName: String
    public var state: PrivilegedHelperState
    public var detail: String

    public init(label: String, plistName: String, state: PrivilegedHelperState, detail: String) {
        self.label = label
        self.plistName = plistName
        self.state = state
        self.detail = detail
    }
}

public protocol MolePrivilegedCommandRunning {
    func run(command: PrivilegedCommand) async throws -> PrivilegedCommandResult
}

public final class MolePrivilegedHelperClient: MolePrivilegedCommandRunning {
    public init() {}

    public func run(command: PrivilegedCommand) async throws -> PrivilegedCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(
                machServiceName: MolePrivilegedHelperConstants.machServiceName,
                options: .privileged
            )
            connection.remoteObjectInterface = NSXPCInterface(with: MolePrivilegedHelperProtocol.self)

            let box = PrivilegedContinuationBox(continuation: continuation, connection: connection)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                box.resume(.failure(PrivilegedHelperClientError.connectionFailed(error.localizedDescription)))
            } as? MolePrivilegedHelperProtocol

            guard let proxy else {
                box.resume(.failure(PrivilegedHelperClientError.connectionFailed("Unable to create privileged helper proxy")))
                return
            }

            connection.resume()
            proxy.runCommand(command.dictionaryRepresentation) { response in
                do {
                    let result = try PrivilegedCommandResult.from(dictionary: response)
                    box.resume(.success(result))
                } catch {
                    box.resume(.failure(error))
                }
            }
        }
    }
}

private final class PrivilegedContinuationBox {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PrivilegedCommandResult, Error>?
    private let connection: NSXPCConnection

    init(continuation: CheckedContinuation<PrivilegedCommandResult, Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(_ result: Result<PrivilegedCommandResult, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        connection.invalidate()
        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

public enum PrivilegedHelperClientError: LocalizedError, Equatable {
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(message):
            "Privileged helper unavailable: \(message)"
        }
    }
}

public final class MolePrivilegedHelperInstaller {
    public init() {}

    public func status() -> PrivilegedHelperStatusSnapshot {
        let service = SMAppService.daemon(plistName: MolePrivilegedHelperConstants.daemonPlistName)
        return PrivilegedHelperStatusSnapshot(
            label: MolePrivilegedHelperConstants.machServiceName,
            plistName: MolePrivilegedHelperConstants.daemonPlistName,
            state: Self.mapStatus(service.status),
            detail: Self.detail(for: service.status)
        )
    }

    public func register() throws {
        try SMAppService.daemon(plistName: MolePrivilegedHelperConstants.daemonPlistName).register()
    }

    public func unregister() throws {
        try SMAppService.daemon(plistName: MolePrivilegedHelperConstants.daemonPlistName).unregister()
    }

    private static func mapStatus(_ status: SMAppService.Status) -> PrivilegedHelperState {
        switch status {
        case .enabled:
            .enabled
        case .notRegistered:
            .notRegistered
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .unknown
        }
    }

    private static func detail(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            "Ready for admin cleanup"
        case .notRegistered:
            "Install once to run admin cleanup without app password dialogs"
        case .requiresApproval:
            "Approval pending in System Settings"
        case .notFound:
            "Helper is not bundled in this app build"
        @unknown default:
            "Helper status is unknown"
        }
    }
}
