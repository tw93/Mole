//
//  Whitelist.swift
//  Tonic
//
//  Whitelist management for protecting paths and apps
//

import Foundation

/// Whitelist manager for protecting paths from cleanup
/// Migrated from Mole's lib/core/base.sh DEFAULT_WHITELIST_PATTERNS
enum Whitelist {
    /// Default whitelist patterns from Mole
    static let defaultPatterns: [String] = [
        // Development caches
        "$HOME/Library/Caches/ms-playwright*",
        "$HOME/.cache/huggingface*",
        "$HOME/.m2/repository/*",
        "$HOME/.ollama/models/*",
        "$HOME/Library/Caches/com.nssurge.surge-mac/*",
        "$HOME/Library/Application Support/com.nssurge.surge-mac/*",
        "$HOME/Library/Caches/org.R-project.R/R/renv/*",
        "$HOME/Library/Caches/pypoetry/virtualenvs*",
        "$HOME/Library/Caches/JetBrains*",
        "$HOME/Library/Caches/com.jetbrains.toolbox*",
        "$HOME/Library/Application Support/JetBrains*",
        "$HOME/Library/Caches/com.apple.finder",

        // Cloud sync directories
        "$HOME/Library/Mobile Documents*",

        // System-critical caches
        "$HOME/Library/Caches/com.apple.FontRegistry*",
        "$HOME/Library/Caches/com.apple.spotlight*",
        "$HOME/Library/Caches/com.apple.Spotlight*",
        "$HOME/Library/Caches/CloudKit*",

        // Finder metadata sentinel
        "FINDER_METADATA",
    ]

    /// Optimization whitelist (items to skip during optimization)
    static let optimizationWhitelist: Set<String> = [
        "check_brew_health",
        "check_touchid",
        "check_git_config",
    ]

    // MARK: - Whitelist Entry

    struct WhitelistEntry: Identifiable, Codable, Hashable {
        let id: UUID
        let pattern: String
        let description: String
        let isEnabled: Bool
        let isDefault: Bool

        init(pattern: String, description: String = "", isEnabled: Bool = true, isDefault: Bool = false) {
            self.id = UUID()
            self.pattern = pattern
            self.description = description
            self.isEnabled = isEnabled
            self.isDefault = isDefault
        }

        /// Expand environment variables in pattern
        var expandedPattern: String {
            pattern.expandingTildeInPath
        }
    }

    // MARK: - Whitelist Store

    @Observable
    final class WhitelistStore {
        private let userDefaultsKey = "whitelistEntries"

        var entries: [WhitelistEntry] = []

        init() {
            loadEntries()
            ensureDefaultEntries()
        }

        private func loadEntries() {
            guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
                  let decoded = try? JSONDecoder().decode([WhitelistEntry].self, from: data) else {
                entries = []
                return
            }
            entries = decoded
        }

        private func saveEntries() {
            guard let encoded = try? JSONEncoder().encode(entries) else { return }
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }

        private func ensureDefaultEntries() {
            let existingPatterns = Set(entries.map { $0.pattern })
            var needsSave = false

            for pattern in Whitelist.defaultPatterns where !existingPatterns.contains(pattern) {
                entries.append(WhitelistEntry(
                    pattern: pattern,
                    description: "Default protected path",
                    isEnabled: true,
                    isDefault: true
                ))
                needsSave = true
            }

            if needsSave {
                saveEntries()
            }
        }

        // MARK: - Public Methods

        func addEntry(pattern: String, description: String = "") {
            let entry = WhitelistEntry(pattern: pattern, description: description)
            entries.append(entry)
            saveEntries()
        }

        func removeEntry(id: UUID) {
            entries.removeAll { $0.id == id }
            saveEntries()
        }

        func toggleEntry(id: UUID) {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index] = WhitelistEntry(
                    pattern: entries[index].pattern,
                    description: entries[index].description,
                    isEnabled: !entries[index].isEnabled,
                    isDefault: entries[index].isDefault
                )
                saveEntries()
            }
        }

        func isPathProtected(_ path: String) -> Bool {
            let normalizedPath = path.expandingTildeInPath

            for entry in entries where entry.isEnabled {
                let pattern = entry.expandedPattern

                // Check if pattern matches path
                if path.matchesWildcard(pattern: pattern) ||
                   normalizedPath.matchesWildcard(pattern: pattern) {
                    return true
                }

                // Check if path is a parent directory of whitelisted path
                if pattern.hasPrefix(normalizedPath) {
                    return true
                }
            }

            return false
        }

        func getActivePatterns() -> [String] {
            entries.filter { $0.isEnabled }.map { $0.expandedPattern }
        }
    }

    // MARK: - Path Validation

    /// Check if a path is safe to clean
    static func isPathSafe(toClean path: String) -> Bool {
        // Check system-critical paths
        let systemCriticalPaths = [
            "/System",
            "/usr/bin",
            "/usr/lib",
            "/bin",
            "/sbin",
            "/private/var",
            "/Library/Preferences",
        ]

        for critical in systemCriticalPaths {
            if path.hasPrefix(critical) {
                return false
            }
        }

        // Check against whitelist
        let store = WhitelistStore()
        return !store.isPathProtected(path)
    }

    /// Validate a path for cleanup operations
    static func validateCleanupPath(_ path: String) -> ValidationResult {
        // Check if path exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .error("Path does not exist")
        }

        // Check if path is within user's home directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) || path.hasPrefix("/Library/Caches") else {
            return .warning("Path is outside safe cleanup area")
        }

        // Check against whitelist
        let store = WhitelistStore()
        if store.isPathProtected(path) {
            return .blocked("Path is protected by whitelist")
        }

        // Check against protected apps
        if ProtectedApps.isPathProtected(path) {
            return .blocked("Path belongs to a protected application")
        }

        return .ok
    }

    enum ValidationResult {
        case ok
        case warning(String)
        case error(String)
        case blocked(String)

        var isAllowed: Bool {
            switch self {
            case .ok, .warning: return true
            case .error, .blocked: return false
            }
        }

        var message: String? {
            switch self {
            case .ok: return nil
            case .warning(let msg), .error(let msg), .blocked(let msg): return msg
            }
        }
    }
}

// MARK: - String Extensions for Whitelist
// Note: matchesWildcard(pattern:) is defined in ProtectedApps.swift

extension String {
    /// Expand tilde to home directory
    var expandingTildeInPath: String {
        replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
