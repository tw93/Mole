//
//  AppMetadata.swift
//  Tonic
//
//  App metadata model for installed applications
//

import Foundation

/// Metadata for an installed application
public struct AppMetadata: Identifiable, Codable, Hashable {
    public let id: UUID
    let bundleIdentifier: String
    let appName: String
    let path: URL
    let version: String?
    let bundleSize: Int64
    let supportSize: Int64
    let cacheSize: Int64
    let lastUsed: Date?
    let installDate: Date?
    let category: AppCategory
    let isProtected: Bool
    let itemType: String // "app", "extension", "prefPane", etc.

    // For UI convenience - can be updated after creation
    var hasUpdate: Bool = false

    var name: String { appName }  // Alias for appName

    var totalSize: Int64 {
        bundleSize + supportSize + cacheSize
    }

    // Convenience initializer with totalSize
    init(
        bundleIdentifier: String,
        appName: String,
        path: URL,
        version: String? = nil,
        totalSize: Int64 = 0,
        lastUsed: Date? = nil,
        installDate: Date? = nil,
        category: AppCategory = .other,
        itemType: String = "app"
    ) {
        self.id = UUID()
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.path = path
        self.version = version
        self.bundleSize = totalSize
        self.supportSize = 0
        self.cacheSize = 0
        self.lastUsed = lastUsed
        self.installDate = installDate
        self.category = category
        self.isProtected = false
        self.hasUpdate = false
        self.itemType = itemType
    }

    init(
        bundleIdentifier: String,
        appName: String,
        path: URL,
        version: String? = nil,
        bundleSize: Int64 = 0,
        supportSize: Int64 = 0,
        cacheSize: Int64 = 0,
        lastUsed: Date? = nil,
        installDate: Date? = nil,
        category: AppCategory = .other,
        isProtected: Bool = false,
        itemType: String = "app"
    ) {
        self.id = UUID()
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.path = path
        self.version = version
        self.bundleSize = bundleSize
        self.supportSize = supportSize
        self.cacheSize = cacheSize
        self.lastUsed = lastUsed
        self.installDate = installDate
        self.category = category
        self.isProtected = isProtected
        self.hasUpdate = false
        self.itemType = itemType
    }

    enum AppCategory: String, CaseIterable, Codable {
        case system = "System"
        case productivity = "Productivity"
        case creativity = "Creativity"
        case development = "Development"
        case communication = "Communication"
        case entertainment = "Entertainment"
        case utilities = "Utilities"
        case security = "Security"
        case social = "Social"
        case games = "Games"
        case education = "Education"
        case finance = "Finance"
        case health = "Health & Fitness"
        case news = "News"
        case weather = "Weather"
        case lifestyle = "Lifestyle"
        case travel = "Travel"
        case reference = "Reference"
        case business = "Business"
        case other = "Other"

        var icon: String {
            switch self {
            case .system: return "desktopcomputer"
            case .productivity: return "checkmark.circle"
            case .creativity: return "paintbrush"
            case .development: return "hammer"
            case .communication: return "message"
            case .entertainment: return "play.rectangle"
            case .utilities: return "wrench.and.screwdriver"
            case .security: return "lock.shield"
            case .social: return "person.2"
            case .games: return "gamecontroller"
            case .education: return "book"
            case .finance: return "dollarsign.circle"
            case .health: return "heart"
            case .news: return "newspaper"
            case .weather: return "cloud.sun"
            case .lifestyle: return "leaf"
            case .travel: return "airplane"
            case .reference: return "bookmark"
            case .business: return "briefcase"
            case .other: return "app"
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bundleIdentifier
        case appName
        case path
        case version
        case bundleSize
        case supportSize
        case cacheSize
        case lastUsed
        case installDate
        case category
        case isProtected
        case itemType
    }
}

/// File locations associated with an app
public struct AppFileLocation: Identifiable, Codable {
    public var id = UUID()
    public let path: String
    public let type: LocationType
    public let size: Int64
    public let lastModified: Date

    public enum LocationType: String, CaseIterable, Codable {
        case appBundle = "Application"
        case appSupport = "Application Support"
        case caches = "Caches"
        case preferences = "Preferences"
        case containers = "Containers"
        case cookies = "Cookies"
        case logs = "Logs"
        case launchAgents = "Launch Agents"
        case savedState = "Saved State"
        case autosave = "Autosave"
        case other = "Other"

        var icon: String {
            switch self {
            case .appBundle: return "app.fill"
            case .appSupport: return "folder.fill"
            case .caches: return "archivebox.fill"
            case .preferences: return "slider.horizontal.3"
            case .containers: return "box.fill"
            case .cookies: return "cookie.fill"
            case .logs: return "doc.text.fill"
            case .launchAgents: return "play.fill"
            case .savedState: return "sleep.fill"
            case .autosave: return "externaldrive.fill"
            case .other: return "doc.fill"
            }
        }
    }
}
