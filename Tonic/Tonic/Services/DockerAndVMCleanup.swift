//
//  DockerAndVMCleanup.swift
//  Tonic
//
//  Docker and Virtual Machine cleanup service
//  Task ID: fn-1.29
//

import Foundation

/// Supported virtualization platforms
public enum VirtualizationPlatform: String, CaseIterable, Identifiable, Sendable {
    case docker = "Docker"
    case virtualbox = "VirtualBox"
    case vmware = "VMware Fusion"
    case parallels = "Parallels Desktop"
    case utm = "UTM"
    case podman = "Podman"
    case lima = "Lima"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .docker: return "shippingbox.fill"
        case .virtualbox: return "cube.box"
        case .vmware: return "server.rack"
        case .parallels: return "rectangle.on.rectangle"
        case .utm: return "cpu"
        case .podman: return "diamond"
        case .lima: return "circle.hexagongrid"
        }
    }

    var commandName: String {
        switch self {
        case .docker: return "docker"
        case .virtualbox: return "VBoxManage"
        case .vmware: return "vmware"
        case .parallels: return "prlctl"
        case .utm: return "utm"
        case .podman: return "podman"
        case .lima: return "lima"
        }
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/usr/local/bin/\(commandName)") ||
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/\(commandName)")
    }
}

/// VM resource type
public enum VMResourceType: String, CaseIterable, Identifiable, Sendable {
    case images = "Images"
    case containers = "Containers"
    case volumes = "Volumes"
    case buildCache = "Build Cache"
    case vms = "Virtual Machines"

    public var id: String { rawValue }
}

/// Result of VM cleanup operation
public struct VMCleanupResult: Sendable {
    let platform: VirtualizationPlatform
    let resourceType: VMResourceType
    let itemCount: Int
    let bytesFreed: Int64
    let success: Bool

    var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }
}

/// Docker and VM cleanup service
@Observable
public final class DockerAndVMCleanup: @unchecked Sendable {

    public static let shared = DockerAndVMCleanup()

    private let fileManager = FileManager.default

    public var isScanning = false
    public var isCleaning = false

    private init() {}

    /// Scan for VM resources
    public func scanPlatform(_ platform: VirtualizationPlatform) async -> [VMResourceType: Int] {
        isScanning = true
        defer { isScanning = false }

        var results: [VMResourceType: Int] = [:]

        switch platform {
        case .docker:
            results = await scanDocker()
        case .virtualbox:
            results = await scanVirtualBox()
        case .vmware:
            results = await scanVMware()
        case .parallels:
            results = await scanParallels()
        default:
            break
        }

        return results
    }

    /// Clean resources for a platform
    public func cleanResources(_ platform: VirtualizationPlatform, types: [VMResourceType]) async throws -> [VMCleanupResult] {
        isCleaning = true
        defer { isCleaning = false }

        var results: [VMCleanupResult] = []

        for type in types {
            let result = try await cleanResourceType(platform, type: type)
            results.append(result)
        }

        return results
    }

    // MARK: - Platform-Specific Scans

    private func scanDocker() async -> [VMResourceType: Int] {
        var results: [VMResourceType: Int] = [:]

        // Check for Docker
        guard FileManager.default.fileExists(atPath: "/usr/local/bin/docker") ||
              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/docker") else {
            return results
        }

        // Get container count
        if let containerCount = await runDockerCommand(["ps", "-aq"]).split(separator: "\n").count as Int?,
           containerCount > 0 {
            results[.containers] = containerCount
        }

        // Get image count
        if let imageCount = await runDockerCommand(["images", "-q"]).split(separator: "\n").count as Int?,
           imageCount > 0 {
            results[.images] = imageCount
        }

        // Get volume count
        if let volumeCount = await runDockerCommand(["volume", "ls", "-q"]).split(separator: "\n").count as Int?,
           volumeCount > 0 {
            results[.volumes] = volumeCount
        }

        // Get build cache size
        let buildCachePath = fileManager.homeDirectoryForCurrentUser.path + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        if fileManager.fileExists(atPath: buildCachePath) {
            results[.buildCache] = 1
        }

        return results
    }

    private func scanVirtualBox() async -> [VMResourceType: Int] {
        var results: [VMResourceType: Int] = [:]

        guard FileManager.default.fileExists(atPath: "/usr/local/bin/VBoxManage") ||
              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/VBoxManage") else {
            return results
        }

        // List VMs
        let vmList = await runCommand("VBoxManage", args: ["list", "vms"])
        let vmCount = vmList.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        if vmCount > 0 {
            results[.vms] = vmCount
        }

        return results
    }

    private func scanVMware() async -> [VMResourceType: Int] {
        // Simplified VMware scan
        let vmPath = fileManager.homeDirectoryForCurrentUser.path + "/Documents/Virtual Machines.localized"
        if fileManager.fileExists(atPath: vmPath) {
            if let vms = try? fileManager.contentsOfDirectory(atPath: vmPath) {
                return [.vms: vms.count]
            }
        }
        return [:]
    }

    private func scanParallels() async -> [VMResourceType: Int] {
        // Simplified Parallels scan
        let vmPath = fileManager.homeDirectoryForCurrentUser.path + "/Parallels"
        if fileManager.fileExists(atPath: vmPath) {
            if let vms = try? fileManager.contentsOfDirectory(atPath: vmPath) {
                return [.vms: vms.count]
            }
        }
        return [:]
    }

    // MARK: - Cleanup Operations

    private func cleanResourceType(_ platform: VirtualizationPlatform, type: VMResourceType) async throws -> VMCleanupResult {
        var itemCount = 0
        var bytesFreed: Int64 = 0
        var success = false

        switch (platform, type) {
        case (.docker, .containers):
            (itemCount, bytesFreed, success) = try await cleanDockerContainers()
        case (.docker, .images):
            (itemCount, bytesFreed, success) = try await cleanDockerImages()
        case (.docker, .volumes):
            (itemCount, bytesFreed, success) = try await cleanDockerVolumes()
        case (.docker, .buildCache):
            (itemCount, bytesFreed, success) = try await cleanDockerBuildCache()
        default:
            success = true // Nothing to clean
        }

        return VMCleanupResult(
            platform: platform,
            resourceType: type,
            itemCount: itemCount,
            bytesFreed: bytesFreed,
            success: success
        )
    }

    private func cleanDockerContainers() async throws -> (Int, Int64, Bool) {
        let output = await runDockerCommand(["ps", "-aq"])
        let containerIds = output.split(separator: "\n").filter { !$0.isEmpty }

        var totalFreed: Int64 = 0
        for containerId in containerIds {
            _ = await runDockerCommand(["rm", "-f", String(containerId)])
            totalFreed += 1024 * 1024 // Estimate
        }

        return (containerIds.count, totalFreed, true)
    }

    private func cleanDockerImages() async throws -> (Int, Int64, Bool) {
        let output = await runDockerCommand(["images", "-q"])
        let imageIds = output.split(separator: "\n").filter { !$0.isEmpty }

        var totalFreed: Int64 = 0
        for imageId in imageIds {
            _ = await runDockerCommand(["rmi", "-f", String(imageId)])
            totalFreed += 10 * 1024 * 1024 // Estimate
        }

        return (imageIds.count, totalFreed, true)
    }

    private func cleanDockerVolumes() async throws -> (Int, Int64, Bool) {
        let output = await runDockerCommand(["volume", "ls", "-q"])
        let volumeNames = output.split(separator: "\n").filter { !$0.isEmpty }

        var totalFreed: Int64 = 0
        for volume in volumeNames {
            _ = await runDockerCommand(["volume", "rm", String(volume)])
            totalFreed += 5 * 1024 * 1024 // Estimate
        }

        return (volumeNames.count, totalFreed, true)
    }

    private func cleanDockerBuildCache() async throws -> (Int, Int64, Bool) {
        _ = await runDockerCommand(["builder", "prune", "-af"])
        _ = await runDockerCommand(["system", "prune", "-af", "--volumes"])

        // Check Docker.raw file size
        let dockerRawPath = fileManager.homeDirectoryForCurrentUser.path + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        let size = await getFileSize(dockerRawPath)

        return (1, size, true)
    }

    // MARK: - Command Helpers

    private func runDockerCommand(_ args: [String]) async -> String {
        return await runCommand("docker", args: args)
    }

    private func runCommand(_ command: String, args: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/\(command)")

        // Try homebrew path if standard doesn't exist
        if !FileManager.default.fileExists(atPath: process.executableURL?.path ?? "") {
            process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/\(command)")
        }

        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func getFileSize(_ path: String) async -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int64 else {
            return 0
        }
        return fileSize
    }
}
