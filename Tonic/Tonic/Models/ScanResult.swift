//
//  ScanResult.swift
//  Tonic
//
//  Scan result models for system cleanup
//

import Foundation

/// Overall scan result with health score
struct ScanResult: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let healthScore: Int // 0-100
    let junkFiles: JunkCategory
    let performanceIssues: PerformanceCategory
    let appIssues: AppIssueCategory
    let privacyIssues: PrivacyCategory
    let totalReclaimableSpace: Int64

    var totalReclaimableSpaceGB: Double {
        Double(totalReclaimableSpace) / (1024 * 1024 * 1024)
    }

    var healthRating: HealthRating {
        switch healthScore {
        case 90...100: return .excellent
        case 75..<90: return .good
        case 50..<75: return .fair
        case 25..<50: return .poor
        default: return .critical
        }
    }

    enum HealthRating: String, Codable {
        case excellent = "Excellent"
        case good = "Good"
        case fair = "Fair"
        case poor = "Poor"
        case critical = "Critical"

        var color: String {
            switch self {
            case .excellent, .good: return "success"
            case .fair: return "warning"
            case .poor, .critical: return "error"
            }
        }

        var icon: String {
            switch self {
            case .excellent: return "star.fill"
            case .good: return "hand.thumbsup.fill"
            case .fair: return "equal"
            case .poor: return "hand.thumbsdown.fill"
            case .critical: return "exclamationmark.triangle.fill"
            }
        }
    }
}

/// Junk file category
struct JunkCategory: Codable {
    let tempFiles: FileGroup
    let cacheFiles: FileGroup
    let logFiles: FileGroup
    let trashItems: FileGroup
    let languageFiles: FileGroup
    let oldFiles: FileGroup

    var totalSize: Int64 {
        tempFiles.size + cacheFiles.size + logFiles.size + trashItems.size + languageFiles.size + oldFiles.size
    }

    var totalFiles: Int {
        tempFiles.count + cacheFiles.count + logFiles.count + trashItems.count + languageFiles.count + oldFiles.count
    }
}

/// Performance issues category
struct PerformanceCategory: Codable {
    let launchAgents: FileGroup
    let loginItems: FileGroup
    let browserCaches: FileGroup
    let memoryIssues: [String]
    let diskFragmentation: Double?
}

/// App-related issues (renamed from AppCategory to avoid conflict with AppMetadata.AppCategory)
struct AppIssueCategory: Codable {
    let unusedApps: [AppMetadata]
    let largeApps: [AppMetadata]
    let duplicateApps: [DuplicateAppGroup]
    let orphanedFiles: [OrphanedFile]
}

/// Privacy-related issues
struct PrivacyCategory: Codable {
    let browserHistory: FileGroup
    let downloadHistory: FileGroup
    let recentDocuments: FileGroup
    let clipboardData: FileGroup
}

/// File group with size and count
struct FileGroup: Codable {
    let name: String
    let description: String
    let paths: [String]
    let size: Int64
    let count: Int

    init(name: String, description: String, paths: [String] = [], size: Int64 = 0, count: Int = 0) {
        self.name = name
        self.description = description
        self.paths = paths
        self.size = size
        self.count = count
    }

    var sizeMB: Double {
        Double(size) / (1024 * 1024)
    }

    var sizeGB: Double {
        Double(size) / (1024 * 1024 * 1024)
    }
}

/// Duplicate app group
struct DuplicateAppGroup: Codable {
    let appName: String
    let versions: [AppMetadata]
    let totalSize: Int64
}

/// Orphaned file from uninstalled apps
struct OrphanedFile: Identifiable, Codable {
    let id: UUID
    let path: String
    let size: Int64
    let type: OrphanType
    let possibleSourceApp: String?

    enum OrphanType: String, CaseIterable, Codable {
        case appSupport = "Application Support"
        case cache = "Cache"
        case preferences = "Preferences"
        case container = "Container"
        case logs = "Logs"
        case launchAgent = "Launch Agent"
        case other = "Other"

        var icon: String {
            switch self {
            case .appSupport: return "folder.fill"
            case .cache: return "archivebox.fill"
            case .preferences: return "slider.horizontal.3"
            case .container: return "box.fill"
            case .logs: return "doc.text.fill"
            case .launchAgent: return "play.fill"
            case .other: return "doc.fill"
            }
        }
    }
}

/// Scan progress state
struct ScanProgress: Identifiable {
    let id: UUID
    let currentPhase: ScanPhase
    let progress: Double // 0.0 to 1.0
    let currentItem: String
    let itemsScanned: Int
    let totalItems: Int

    enum ScanPhase: String, CaseIterable {
        case discovering = "Discovering files"
        case analyzing = "Analyzing content"
        case calculating = "Calculating sizes"
        case complete = "Scan complete"

        var icon: String {
            switch self {
            case .discovering: return "magnifyingglass"
            case .analyzing: return "magnifyingglass.circle"
            case .calculating: return "chart.bar"
            case .complete: return "checkmark.circle.fill"
            }
        }
    }
}

/// Scan configuration
struct ScanConfiguration: Codable {
    var scanTempFiles: Bool
    var scanCacheFiles: Bool
    var scanLogFiles: Bool
    var scanTrash: Bool
    var scanLanguageFiles: Bool
    var scanOldFiles: Bool
    var scanLaunchAgents: Bool
    var scanLoginItems: Bool
    var scanBrowserData: Bool
    var scanOrphanedFiles: Bool

    var oldFileThresholdDays: Int

    static let `default` = ScanConfiguration(
        scanTempFiles: true,
        scanCacheFiles: true,
        scanLogFiles: true,
        scanTrash: true,
        scanLanguageFiles: false,
        scanOldFiles: true,
        scanLaunchAgents: true,
        scanLoginItems: true,
        scanBrowserData: false,
        scanOrphanedFiles: true,
        oldFileThresholdDays: 90
    )

    static let aggressive = ScanConfiguration(
        scanTempFiles: true,
        scanCacheFiles: true,
        scanLogFiles: true,
        scanTrash: true,
        scanLanguageFiles: true,
        scanOldFiles: true,
        scanLaunchAgents: true,
        scanLoginItems: true,
        scanBrowserData: true,
        scanOrphanedFiles: true,
        oldFileThresholdDays: 60
    )
}
