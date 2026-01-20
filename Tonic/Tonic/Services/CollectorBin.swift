//
//  CollectorBin.swift
//  Tonic
//
//  Virtual deletion staging area (Collector Bin)
// Files are marked for deletion and can be reviewed before actual deletion
//

import Foundation

// MARK: - Bin Item

public struct BinItem: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public let originalPath: String
    public let fileName: String
    public let fileSize: Int64
    public let itemType: BinItemType
    public let addedDate: Date
    public var thumbnailData: Data?
    public var tags: [String]

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    public var `extension`: String {
        (fileName as NSString).pathExtension
    }

    public var iconName: String {
        switch itemType {
        case .file:
            return "doc.fill"
        case .directory:
            return "folder.fill"
        case .application:
            return "app.fill"
        case .archive:
            return "archivebox.fill"
        case .cache:
            return "archivebox.fill"
        case .log:
            return "doc.text.fill"
        case .temp:
            return "clock.fill"
        }
    }

    public init(
        id: UUID = UUID(),
        originalPath: String,
        fileName: String,
        fileSize: Int64,
        itemType: BinItemType,
        addedDate: Date = Date(),
        thumbnailData: Data? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.originalPath = originalPath
        self.fileName = fileName
        self.fileSize = fileSize
        self.itemType = itemType
        self.addedDate = addedDate
        self.thumbnailData = thumbnailData
        self.tags = tags
    }

    public enum CodingKeys: String, CodingKey {
        case id, originalPath, fileName, fileSize, itemType, addedDate, thumbnailData, tags
    }
}

public enum BinItemType: String, Sendable, Codable, CaseIterable {
    case file = "File"
    case directory = "Directory"
    case application = "Application"
    case archive = "Archive"
    case cache = "Cache"
    case log = "Log"
    case temp = "Temporary"

    public var color: String {
        switch self {
        case .file: return "blue"
        case .directory: return "purple"
        case .application: return "green"
        case .archive: return "orange"
        case .cache: return "yellow"
        case .log: return "gray"
        case .temp: return "red"
        }
    }
}

// MARK: - Bin Statistics

public struct BinStatistics: Sendable, Identifiable {
    public let id = UUID()
    public let totalItems: Int
    public let totalSize: Int64
    public let fileCount: Int
    public let directoryCount: Int
    public let applicationCount: Int
    public let oldestItemDate: Date?
    public let newestItemDate: Date?
    public let categoryBreakdown: [BinItemType: Int]

    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    public var totalSizeGB: Double {
        Double(totalSize) / (1024 * 1024 * 1024)
    }
}

// MARK: - Bin Restoration Result

public struct BinRestorationResult: Sendable {
    public let success: Bool
    public let restoredItems: Int
    public let failedItems: Int
    public let restoredSize: Int64
    public let errors: [BinRestorationError]

    public var formattedRestoredSize: String {
        ByteCountFormatter.string(fromByteCount: restoredSize, countStyle: .file)
    }
}

public struct BinRestorationError: Sendable, Error {
    public let itemId: UUID
    public let itemName: String
    public let reason: RestorationFailureReason

    public enum RestorationFailureReason {
        case fileNotFound
        case permissionDenied
        case diskFull
        case pathConflict
        case unknown
    }
}

// MARK: - Empty Bin Result

public struct EmptyBinResult: Sendable {
    public let success: Bool
    public let deletedItems: Int
    public let freedSpace: Int64
    public let skippedItems: Int
    public let errors: [String]

    public var formattedFreedSpace: String {
        ByteCountFormatter.string(fromByteCount: freedSpace, countStyle: .file)
    }
}

// MARK: - Collector Bin

@Observable
public final class CollectorBin: @unchecked Sendable {

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let lock = NSLock()

    private var _items: [BinItem] = []
    private var _isEmptying = false
    private var _isRestoring = false

    /// Items currently in the bin
    public var items: [BinItem] {
        get { lock.locked { _items } }
        set { lock.locked { _items = newValue } }
    }

    /// Whether the bin is currently being emptied
    public var isEmptying: Bool {
        get { lock.locked { _isEmptying } }
        set { lock.locked { _isEmptying = newValue } }
    }

    /// Whether items are currently being restored
    public var isRestoring: Bool {
        get { lock.locked { _isRestoring } }
        set { lock.locked { _isRestoring = newValue } }
    }

    /// Storage path for bin metadata
    private let binStoragePath: String

    /// Maximum items allowed in bin (0 = unlimited)
    public var maxItems: Int = 10000

    /// Maximum total size in bytes (0 = unlimited)
    public var maxTotalSize: Int64 = 50 * 1024 * 1024 * 1024 // 50 GB default

    // MARK: - Singleton

    public static let shared = CollectorBin()

    private init() {
        // Set up storage path in Application Support
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tonicFolder = appSupportURL.appendingPathComponent("Tonic", isDirectory: true)
        let binFolder = tonicFolder.appendingPathComponent("CollectorBin", isDirectory: true)

        try? fileManager.createDirectory(at: tonicFolder, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: binFolder, withIntermediateDirectories: true)

        binStoragePath = binFolder.path

        // Load existing items
        loadItems()
    }

    // MARK: - Add Items

    /// Add items to the bin (marks them for deletion)
    public func addToBin(atPaths paths: [String]) async -> (added: Int, failed: Int, totalSize: Int64) {
        var addedCount = 0
        var failedCount = 0
        var totalSize: Int64 = 0

        for path in paths {
            let result = await addToBin(atPath: path)
            if result.success {
                addedCount += 1
                totalSize += result.size
            } else {
                failedCount += 1
            }
        }

        saveItems()
        return (addedCount, failedCount, totalSize)
    }

    /// Add a single item to the bin
    public func addToBin(atPath path: String) async -> (success: Bool, size: Int64) {
        let expandedPath = (path as NSString).expandingTildeInPath

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expandedPath, isDirectory: &isDirectory) else {
            return (false, 0)
        }

        // Check if item is already in bin
        if items.contains(where: { $0.originalPath == expandedPath }) {
            return (false, 0)
        }

        let fileName = (expandedPath as NSString).lastPathComponent
        let itemType = determineItemType(for: expandedPath, isDirectory: isDirectory.boolValue)

        // Calculate size
        let size: Int64
        if isDirectory.boolValue {
            size = await calculateDirectorySize(at: expandedPath)
        } else {
            if let attrs = try? fileManager.attributesOfItem(atPath: expandedPath),
               let fileSize = attrs[.size] as? Int64 {
                size = fileSize
            } else {
                size = 0
            }
        }

        // Check bin limits
        if maxItems > 0 && items.count >= maxItems {
            return (false, 0)
        }

        if maxTotalSize > 0 && (getCurrentTotalSize() + size) > maxTotalSize {
            return (false, 0)
        }

        let item = BinItem(
            originalPath: expandedPath,
            fileName: fileName,
            fileSize: size,
            itemType: itemType
        )

        items.append(item)
        saveItems()

        return (true, size)
    }

    /// Add items from a scan result
    public func addScanResults(_ scanResults: [String]) async -> Int {
        var addedCount = 0

        for path in scanResults {
            let result = await addToBin(atPath: path)
            if result.success {
                addedCount += 1
            }
        }

        return addedCount
    }

    // MARK: - Remove Items

    /// Remove items from the bin (restore/unmark)
    public func removeFromBin(itemIds: [UUID]) async -> Bool {
        items.removeAll { item in
            itemIds.contains(item.id)
        }
        saveItems()
        return true
    }

    /// Remove a single item from the bin
    public func removeFromBin(itemId: UUID) async -> Bool {
        items.removeAll { $0.id == itemId }
        saveItems()
        return true
    }

    /// Clear all items from the bin without deleting them
    public func clearBin() async {
        items.removeAll()
        saveItems()
    }

    // MARK: - Restore Items

    /// Restore items from the bin to their original locations
    public func restoreItems(itemIds: [UUID]) async -> BinRestorationResult {
        isRestoring = true
        defer { isRestoring = false }

        var restoredCount = 0
        var failedCount = 0
        var restoredSize: Int64 = 0
        var errors: [BinRestorationError] = []

        let itemsToRestore = items.filter { itemIds.contains($0.id) }

        for item in itemsToRestore {
            // Check if original path still exists
            if fileManager.fileExists(atPath: item.originalPath) {
                // Item still exists, just remove from bin
                restoredCount += 1
                restoredSize += item.fileSize
            } else {
                // Item no longer exists at original path - might need to restore from backup
                errors.append(BinRestorationError(
                    itemId: item.id,
                    itemName: item.fileName,
                    reason: .fileNotFound
                ))
                failedCount += 1
            }
        }

        // Remove restored items from bin
        await removeFromBin(itemIds: itemIds)

        return BinRestorationResult(
            success: failedCount == 0,
            restoredItems: restoredCount,
            failedItems: failedCount,
            restoredSize: restoredSize,
            errors: errors
        )
    }

    /// Restore all items from the bin
    public func restoreAll() async -> BinRestorationResult {
        let allIds = items.map { $0.id }
        return await restoreItems(itemIds: allIds)
    }

    // MARK: - Empty Bin

    /// Empty the bin (perform actual deletion)
    public func emptyBin(confirm: Bool = false) async -> EmptyBinResult {
        guard confirm else {
            return EmptyBinResult(
                success: false,
                deletedItems: 0,
                freedSpace: 0,
                skippedItems: 0,
                errors: ["Confirmation required"]
            )
        }

        isEmptying = true
        defer { isEmptying = false }

        var deletedCount = 0
        var freedSpace: Int64 = 0
        var skippedCount = 0
        var errors: [String] = []

        let fileOps = FileOperations.shared

        // Delete items in batches
        let batchSize = 100
        let itemIds = items.map { $0.id }

        for batch in stride(from: 0, to: itemIds.count, by: batchSize) {
            let batchEnd = min(batch + batchSize, itemIds.count)
            let batchIds = Array(itemIds[batch..<batchEnd])

            let batchItems = items.filter { batchIds.contains($0.id) }
            let paths = batchItems.map { $0.originalPath }

            // Validate paths first
            let (safePaths, protectedPaths) = fileOps.validatePathsForDeletion(paths)

            // Delete safe paths
            let safeResult = await fileOps.deleteFiles(atPaths: safePaths, usePrivileged: true)
            deletedCount += safeResult.filesProcessed
            freedSpace += safeResult.bytesFreed

            // Log protected paths
            for path in protectedPaths {
                skippedCount += 1
                errors.append("Protected: \(path)")
            }

            // Collect errors
            for error in safeResult.errors {
                errors.append(error.errorDescription ?? "Unknown error")
            }
        }

        // Clear the bin
        await clearBin()

        return EmptyBinResult(
            success: errors.isEmpty || deletedCount > 0,
            deletedItems: deletedCount,
            freedSpace: freedSpace,
            skippedItems: skippedCount,
            errors: errors
        )
    }

    // MARK: - Query Methods

    /// Get statistics about the bin contents
    public func getStatistics() -> BinStatistics {
        let totalItems = items.count
        let totalSize = items.reduce(0) { $0 + $1.fileSize }

        let fileCount = items.filter { $0.itemType == .file }.count
        let directoryCount = items.filter { $0.itemType == .directory }.count
        let applicationCount = items.filter { $0.itemType == .application }.count

        let dates = items.map { $0.addedDate }
        let oldestDate = dates.min()
        let newestDate = dates.max()

        var categoryBreakdown: [BinItemType: Int] = [:]
        for type in BinItemType.allCases {
            categoryBreakdown[type] = items.filter { $0.itemType == type }.count
        }

        return BinStatistics(
            totalItems: totalItems,
            totalSize: totalSize,
            fileCount: fileCount,
            directoryCount: directoryCount,
            applicationCount: applicationCount,
            oldestItemDate: oldestDate,
            newestItemDate: newestDate,
            categoryBreakdown: categoryBreakdown
        )
    }

    /// Get items filtered by type
    public func getItems(ofType type: BinItemType) -> [BinItem] {
        items.filter { $0.itemType == type }
    }

    /// Get items filtered by tag
    public func getItems(withTag tag: String) -> [BinItem] {
        items.filter { $0.tags.contains(tag) }
    }

    /// Search items by name
    public func searchItems(query: String) -> [BinItem] {
        items.filter { item in
            item.fileName.localizedCaseInsensitiveContains(query)
        }
    }

    /// Get items sorted by size
    public func getItemsSortedBySize(ascending: Bool = false) -> [BinItem] {
        items.sorted { item1, item2 in
            ascending ? item1.fileSize < item2.fileSize : item1.fileSize > item2.fileSize
        }
    }

    /// Get items sorted by date
    public func getItemsSortedByDate(ascending: Bool = true) -> [BinItem] {
        items.sorted { item1, item2 in
            ascending ? item1.addedDate < item2.addedDate : item1.addedDate > item2.addedDate
        }
    }

    /// Get top largest items
    public func getLargestItems(count: Int = 10) -> [BinItem] {
        Array(getItemsSortedBySize(ascending: false).prefix(count))
    }

    // MARK: - Helper Methods

    private func determineItemType(for path: String, isDirectory: Bool) -> BinItemType {
        if isDirectory {
            let ext = ((path as NSString).pathExtension).lowercased()

            // Check for app bundles
            if ext == "app" {
                return .application
            }

            // Check for common cache directories
            let cacheIndicators = ["cache", "caches", "tmp", "temp", ".cache"]
            let pathLower = path.lowercased()
            for indicator in cacheIndicators {
                if pathLower.contains(indicator) {
                    return .cache
                }
            }

            return .directory
        } else {
            let ext = ((path as NSString).pathExtension).lowercased()

            // Archive types
            let archiveExtensions = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"]
            if archiveExtensions.contains(ext) {
                return .archive
            }

            // Log files
            if ext == "log" || path.contains(".log") {
                return .log
            }

            // Temp files
            let tempExtensions = ["tmp", "temp", "cache", "dmg", "part"]
            if tempExtensions.contains(ext) || path.hasPrefix(".") {
                return .temp
            }

            return .file
        }
    }

    private func calculateDirectorySize(at path: String) async -> Int64 {
        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                   let isDirectory = resourceValues.isDirectory,
                   !isDirectory {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            }
        }

        return totalSize
    }

    private func getCurrentTotalSize() -> Int64 {
        items.reduce(0) { $0 + $1.fileSize }
    }

    // MARK: - Persistence

    private func saveItems() {
        do {
            let data = try JSONEncoder().encode(items)
            let path = (binStoragePath as NSString).appendingPathComponent("bin_items.json")
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("Failed to save bin items: \(error)")
        }
    }

    private func loadItems() {
        let path = (binStoragePath as NSString).appendingPathComponent("bin_items.json")

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return
        }

        do {
            _items = try JSONDecoder().decode([BinItem].self, from: data)
        } catch {
            print("Failed to load bin items: \(error)")
            _items = []
        }
    }

    /// Export bin manifest for backup
    public func exportManifest() -> Data? {
        let manifest: [String: Any] = [
            "version": 1,
            "exportDate": ISO8601DateFormatter().string(from: Date()),
            " itemCount": items.count,
            "totalSize": getCurrentTotalSize(),
            "items": items.map { item in
                [
                    "id": item.id.uuidString,
                    "originalPath": item.originalPath,
                    "fileName": item.fileName,
                    "fileSize": item.fileSize,
                    "itemType": item.itemType.rawValue,
                    "addedDate": ISO8601DateFormatter().string(from: item.addedDate)
                ]
            }
        ]

        return try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
    }

    /// Import bin manifest
    public func importManifest(data: Data) async -> Bool {
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = manifest["version"] as? Int,
              version == 1 else {
            return false
        }

        // Items would be imported here
        saveItems()
        return true
    }
}
