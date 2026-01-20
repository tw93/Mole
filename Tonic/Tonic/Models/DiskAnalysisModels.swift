//
//  DiskAnalysisModels.swift
//  Tonic
//
//  Models for disk analysis functionality
//

import Foundation

/// Represents a file or folder on disk with size information
struct DiskItem: Identifiable, Hashable {
    let id: UUID = UUID()
    let name: String
    let path: String
    let size: Int64
    let type: DiskItemType
    var children: [DiskItem] = []
    var isExpanded: Bool = false

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var icon: String {
        switch type {
        case .directory:
            return "folder.fill"
        case .file:
            return "doc.fill"
        case .package:
            return "archivebox.fill"
        }
    }
}

enum DiskItemType {
    case file
    case directory
    case package
}

/// Represents a disk analysis result
struct DiskAnalysisResult {
    let rootPath: String
    let rootItem: DiskItem
    let totalSize: Int64
    let scanDate: Date
    let duration: TimeInterval

    var totalSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}

/// Represents a category of file types
struct FileCategory: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let extensions: [String]
    var totalSize: Int64 = 0
    var itemCount: Int = 0
    let color: String

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    static let commonCategories: [FileCategory] = [
        FileCategory(name: "Images", extensions: ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "heic"], totalSize: 0, itemCount: 0, color: "blue"),
        FileCategory(name: "Videos", extensions: ["mp4", "mov", "avi", "mkv", "flv", "wmv", "webm"], totalSize: 0, itemCount: 0, color: "purple"),
        FileCategory(name: "Audio", extensions: ["mp3", "m4a", "wav", "flac", "aac", "ogg"], totalSize: 0, itemCount: 0, color: "orange"),
        FileCategory(name: "Documents", extensions: ["pdf", "doc", "docx", "txt", "rtf", "pages"], totalSize: 0, itemCount: 0, color: "gray"),
        FileCategory(name: "Archives", extensions: ["zip", "rar", "7z", "tar", "gz", "bz2"], totalSize: 0, itemCount: 0, color: "brown"),
    ]
}

/// Configuration for disk scanning
struct DiskScanConfiguration {
    var includeHiddenFiles: Bool = false
    var includeSystemFiles: Bool = false
    var maxDepth: Int = 5
    var excludePatterns: [String] = []
    var minimumFileSize: Int64 = 0

    static let `default` = DiskScanConfiguration()
}
