//
//  ProjectArtifactPurge.swift
//  Tonic
//
//  Project artifact cleanup service
//  Task ID: fn-1.28
//

import Foundation

/// Project types with specific artifact patterns
public enum ProjectType: String, CaseIterable, Identifiable {
    case node = "Node.js"
    case python = "Python"
    case ruby = "Ruby"
    case java = "Java"
    case dotnet = ".NET"
    case go = "Go"
    case rust = "Rust"
    case swift = "Swift"
    case flutter = "Flutter"
    case docker = "Docker"
    case generic = "Generic"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .node: return "nodejs"
        case .python: return "python"
        case .ruby: return "ruby"
        case .java: return "java"
        case .dotnet: return "dotnet"
        case .go: return "globe"
        case .rust: return "hammer"
        case .swift: return "swift"
        case .flutter: return "butterfly"
        case .docker: return "shippingbox"
        case .generic: return "folder.fill"
        }
    }

    var identifierFiles: [String] {
        switch self {
        case .node:
            return ["package.json", "package-lock.json", "yarn.lock", "node_modules/"]
        case .python:
            return ["requirements.txt", "setup.py", "Pipfile", "pyproject.toml", "__pycache__/"]
        case .ruby:
            return ["Gemfile", "Gemfile.lock", ".bundle/"]
        case .java:
            return ["pom.xml", "build.gradle", "gradlew"]
        case .dotnet:
            return ["*.csproj", "*.sln", "packages/"]
        case .go:
            return ["go.mod", "go.sum"]
        case .rust:
            return ["Cargo.toml", "Cargo.lock", "target/"]
        case .swift:
            return ["Package.swift", ".build/"]
        case .flutter:
            return ["pubspec.yaml", "build/"]
        case .docker:
            return ["Dockerfile", "docker-compose.yml"]
        case .generic:
            return [".git/"]
        }
    }
}

/// Project artifact result
public struct ProjectArtifactResult: Sendable {
    let projectPath: String
    let projectType: ProjectType
    let artifacts: [Artifact]
    let totalSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

/// Individual artifact
public struct Artifact: Sendable {
    let name: String
    let path: String
    let size: Int64
    let type: ArtifactType

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// Artifact type classification
public enum ArtifactType: String, CaseIterable, Identifiable {
    case dependencies = "Dependencies"
    case buildCache = "Build Cache"
    case logs = "Logs"
    case temp = "Temporary Files"
    case ide = "IDE Files"
    case docker = "Docker Images"
    case git = "Git Objects"

    public var id: String { rawValue }

    var isSafeToDelete: Bool {
        switch self {
        case .dependencies, .buildCache, .logs, .temp, .docker:
            return true
        case .ide, .git:
            return false
        }
    }
}

/// Project artifact scanner and cleaner
@Observable
public final class ProjectArtifactPurge: @unchecked Sendable {

    public static let shared = ProjectArtifactPurge()

    private let fileManager = FileManager.default

    private var isScanning = false
    public var scanProgress: Double = 0
    public var currentScanningPath: String?

    private init() {}

    /// Scan a directory for project artifacts
    public func scanDirectory(_ path: String) async -> [ProjectArtifactResult] {
        isScanning = true
        defer { isScanning = false }

        var results: [ProjectArtifactResult] = []

        guard fileManager.fileExists(atPath: path) else { return results }

        // Find project directories
        let projectDirs = await findProjectDirectories(in: path)

        for projectDir in projectDirs {
            currentScanningPath = projectDir
            if let result = await scanProject(projectDir) {
                results.append(result)
            }
        }

        currentScanningPath = nil
        scanProgress = 1.0

        return results
    }

    /// Scan user's home directory for projects
    public func scanUserProjects() async -> [ProjectArtifactResult] {
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        return await scanDirectory(homeDir)
    }

    /// Clean artifacts from specific projects
    public func cleanArtifacts(_ results: [ProjectArtifactResult], artifactTypes: [ArtifactType]) async -> Int64 {
        var bytesFreed: Int64 = 0

        for result in results {
            for artifact in result.artifacts {
                guard artifactTypes.contains(artifact.type) else { continue }
                guard artifact.type.isSafeToDelete else { continue }

                do {
                    let attrs = try? fileManager.attributesOfItem(atPath: artifact.path)
                    let size = attrs?[.size] as? Int64 ?? 0

                    try fileManager.removeItem(atPath: artifact.path)
                    bytesFreed += size
                } catch {
                    // Skip items that can't be deleted
                    continue
                }
            }
        }

        return bytesFreed
    }

    // MARK: - Project Detection

    private func findProjectDirectories(in path: String) async -> [String] {
        var projectDirs: Set<String> = []

        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        var currentURL: URL?
        while let url = enumerator.nextObject() as? URL {
            currentURL = url
            guard let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory else { continue }
            guard isDirectory == true else { continue }

            let foundPath = url.path

            // Check if this is a project directory
            if detectProjectType(at: foundPath) != nil {
                projectDirs.insert(foundPath)
            }
        }

        return Array(projectDirs)
    }

    private func detectProjectType(at path: String) -> ProjectType? {
        for type in ProjectType.allCases {
            for identifier in type.identifierFiles {
                var checkPath = path + "/" + identifier

                // Handle wildcard patterns
                if identifier.hasPrefix("*") {
                    let fileExt = String(identifier.dropFirst())
                    if let contents = try? fileManager.contentsOfDirectory(atPath: path) {
                        if contents.contains(where: { $0.hasSuffix(fileExt) }) {
                            return type
                        }
                    }
                } else if identifier.hasSuffix("/") {
                    // Directory check
                    let dirPath = String(identifier.dropLast())
                    if fileManager.fileExists(atPath: checkPath) {
                        var isDirectory: ObjCBool = false
                        fileManager.fileExists(atPath: checkPath, isDirectory: &isDirectory)
                        if isDirectory.boolValue {
                            return type
                        }
                    }
                } else {
                    // File check
                    if fileManager.fileExists(atPath: checkPath) {
                        return type
                    }
                }
            }
        }

        return nil
    }

    // MARK: - Project Scanning

    private func scanProject(_ path: String) async -> ProjectArtifactResult? {
        guard let type = detectProjectType(at: path) else { return nil }

        var artifacts: [Artifact] = []

        switch type {
        case .node:
            artifacts.append(contentsOf: await scanNodeProject(path))
        case .python:
            artifacts.append(contentsOf: await scanPythonProject(path))
        case .ruby:
            artifacts.append(contentsOf: await scanRubyProject(path))
        case .java:
            artifacts.append(contentsOf: await scanJavaProject(path))
        case .dotnet:
            artifacts.append(contentsOf: await scanDotNetProject(path))
        case .go:
            artifacts.append(contentsOf: await scanGoProject(path))
        case .rust:
            artifacts.append(contentsOf: await scanRustProject(path))
        case .swift:
            artifacts.append(contentsOf: await scanSwiftProject(path))
        case .flutter:
            artifacts.append(contentsOf: await scanFlutterProject(path))
        case .docker:
            artifacts.append(contentsOf: await scanDockerProject(path))
        case .generic:
            artifacts.append(contentsOf: await scanGenericProject(path))
        }

        let totalSize = artifacts.reduce(0) { $0 + $1.size }

        return ProjectArtifactResult(
            projectPath: path,
            projectType: type,
            artifacts: artifacts,
            totalSize: totalSize
        )
    }

    // MARK: - Language-Specific Scanners

    private func scanNodeProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // node_modules
        let nodeModules = path + "/node_modules"
        if let size = await getDirectorySize(nodeModules) {
            artifacts.append(Artifact(name: "node_modules", path: nodeModules, size: size, type: .dependencies))
        }

        // .npm cache
        let npmCache = fileManager.homeDirectoryForCurrentUser.path + "/.npm"
        if let size = await getDirectorySize(npmCache) {
            artifacts.append(Artifact(name: ".npm cache", path: npmCache, size: size, type: .buildCache))
        }

        // yarn cache
        let yarnCache = fileManager.homeDirectoryForCurrentUser.path + "/.yarn/cache"
        if let size = await getDirectorySize(yarnCache) {
            artifacts.append(Artifact(name: "Yarn cache", path: yarnCache, size: size, type: .buildCache))
        }

        // TypeScript cache
        let tsBuildInfo = path + "/tsconfig.tsbuildinfo"
        if let size = await getFileSize(tsBuildInfo) {
            artifacts.append(Artifact(name: "TS build info", path: tsBuildInfo, size: size, type: .buildCache))
        }

        // Next.js cache
        let nextCache = path + "/.next"
        if let size = await getDirectorySize(nextCache) {
            artifacts.append(Artifact(name: "Next.js cache", path: nextCache, size: size, type: .buildCache))
        }

        return artifacts
    }

    private func scanPythonProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // __pycache__
        let pycache = path + "/__pycache__"
        if let size = await getDirectorySize(pycache) {
            artifacts.append(Artifact(name: "__pycache__", path: pycache, size: size, type: .buildCache))
        }

        // .pytest_cache
        let pytestCache = path + "/.pytest_cache"
        if let size = await getDirectorySize(pytestCache) {
            artifacts.append(Artifact(name: "pytest cache", path: pytestCache, size: size, type: .buildCache))
        }

        // .mypy_cache
        let mypyCache = path + "/.mypy_cache"
        if let size = await getDirectorySize(mypyCache) {
            artifacts.append(Artifact(name: "mypy cache", path: mypyCache, size: size, type: .buildCache))
        }

        // .venv or venv
        for venvName in ["venv", ".venv", "env", ".env"] {
            let venv = path + "/" + venvName
            if let size = await getDirectorySize(venv) {
                artifacts.append(Artifact(name: venvName, path: venv, size: size, type: .dependencies))
                break
            }
        }

        return artifacts
    }

    private func scanRubyProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // vendor/bundle
        let vendor = path + "/vendor/bundle"
        if let size = await getDirectorySize(vendor) {
            artifacts.append(Artifact(name: "vendor/bundle", path: vendor, size: size, type: .dependencies))
        }

        return artifacts
    }

    private func scanJavaProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // target (Maven)
        let target = path + "/target"
        if let size = await getDirectorySize(target) {
            artifacts.append(Artifact(name: "Maven target", path: target, size: size, type: .buildCache))
        }

        // build (Gradle)
        let build = path + "/build"
        if let size = await getDirectorySize(build) {
            artifacts.append(Artifact(name: "Gradle build", path: build, size: size, type: .buildCache))
        }

        // .gradle cache
        let gradleCache = fileManager.homeDirectoryForCurrentUser.path + "/.gradle/caches"
        if let size = await getDirectorySize(gradleCache) {
            artifacts.append(Artifact(name: ".gradle caches", path: gradleCache, size: size, type: .buildCache))
        }

        return artifacts
    }

    private func scanDotNetProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // bin/obj
        for dirName in ["bin", "obj"] {
            let dir = path + "/" + dirName
            if let size = await getDirectorySize(dir) {
                artifacts.append(Artifact(name: dirName, path: dir, size: size, type: .buildCache))
            }
        }

        return artifacts
    }

    private func scanGoProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // Go module cache
        let goModCache = fileManager.homeDirectoryForCurrentUser.path + "/go/pkg/mod"
        if let size = await getDirectorySize(goModCache) {
            artifacts.append(Artifact(name: "Go modules", path: goModCache, size: size, type: .dependencies))
        }

        return artifacts
    }

    private func scanRustProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // target/
        let target = path + "/target"
        if let size = await getDirectorySize(target) {
            artifacts.append(Artifact(name: "Cargo target", path: target, size: size, type: .buildCache))
        }

        return artifacts
    }

    private func scanSwiftProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // .build/
        let build = path + "/.build"
        if let size = await getDirectorySize(build) {
            artifacts.append(Artifact(name: "SwiftPM build", path: build, size: size, type: .buildCache))
        }

        // .swiftpm/
        let swiftpm = path + "/.swiftpm"
        if let size = await getDirectorySize(swiftpm) {
            artifacts.append(Artifact(name: ".swiftpm cache", path: swiftpm, size: size, type: .buildCache))
        }

        // DerivedData (if Xcode project)
        let projectName = (path as NSString).lastPathComponent
        let derivedDataPath = fileManager.homeDirectoryForCurrentUser.path + "/Library/Developer/Xcode/DerivedData"
        if let dirs = try? fileManager.contentsOfDirectory(atPath: derivedDataPath) {
            for dir in dirs {
                if dir.contains(projectName) {
                    let dirPath = derivedDataPath + "/" + dir
                    if let size = await getDirectorySize(dirPath) {
                        artifacts.append(Artifact(name: "DerivedData", path: dirPath, size: size, type: .buildCache))
                    }
                }
            }
        }

        return artifacts
    }

    private func scanFlutterProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // build/
        let build = path + "/build"
        if let size = await getDirectorySize(build) {
            artifacts.append(Artifact(name: "Flutter build", path: build, size: size, type: .buildCache))
        }

        // .dart_tool
        let dartTool = path + "/.dart_tool"
        if let size = await getDirectorySize(dartTool) {
            artifacts.append(Artifact(name: ".dart_tool", path: dartTool, size: size, type: .buildCache))
        }

        return artifacts
    }

    private func scanDockerProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // This would be handled by DockerAndVMCleanup service
        return artifacts
    }

    private func scanGenericProject(_ path: String) async -> [Artifact] {
        var artifacts: [Artifact] = []

        // Common IDE folders
        let ideFolders = [
            ".idea",
            ".vscode",
            ".vs",
            "*.swp",
            "*.swo",
            ".DS_Store"
        ]

        return artifacts
    }

    // MARK: - Helper Methods

    private func getDirectorySize(_ path: String) async -> Int64? {
        guard fileManager.fileExists(atPath: path) else { return nil }

        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) {
            var url: URL?
            while let current = enumerator.nextObject() as? URL {
                url = current
                if let size = await getFileSize(current.path) {
                    totalSize += size
                }
            }
        }

        return totalSize > 0 ? totalSize : nil
    }

    private func getFileSize(_ path: String) async -> Int64? {
        guard fileManager.fileExists(atPath: path) else { return nil }

        do {
            let attrs = try fileManager.attributesOfItem(atPath: path)
            return attrs[.size] as? Int64
        } catch {
            return nil
        }
    }
}
