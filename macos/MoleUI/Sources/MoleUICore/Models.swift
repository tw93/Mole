import Foundation

public enum MoleSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case cleanup = "Cleanup"
    case applications = "Applications"
    case storage = "Storage"
    case performance = "Performance"
    case monitor = "Monitor"
    case settings = "Settings"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .home: "gauge.with.dots.needle.bottom.50percent"
        case .cleanup: "sparkles"
        case .applications: "app.badge"
        case .storage: "internaldrive"
        case .performance: "speedometer"
        case .monitor: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }
}

public enum ExecutionDomain: String, CaseIterable, Identifiable {
    case clean
    case uninstall
    case purge
    case installer
    case optimize
    case update
    case remove

    public var id: String { rawValue }
}

public struct StatusSnapshot: Decodable, Equatable {
    public var collectedAt: Date?
    public var host: String?
    public var platform: String?
    public var uptime: String?
    public var healthScore: Int?
    public var healthScoreMessage: String?
    public var hardware: HardwareStatus?
    public var cpu: CPUStatus?
    public var gpu: [GPUStatus]
    public var memory: MemoryStatus?
    public var disks: [DiskStatus]
    public var diskIO: DiskIOStatus?
    public var proxy: ProxyStatus?
    public var batteries: [BatteryStatus]
    public var thermal: ThermalStatus?
    public var bluetooth: [BluetoothStatus]
    public var network: [NetworkStatus]
    public var topProcesses: [ProcessInfo]
    public var processAlerts: [ProcessAlert]

    enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at"
        case host
        case platform
        case uptime
        case healthScore = "health_score"
        case healthScoreMessage = "health_score_msg"
        case hardware
        case cpu
        case gpu
        case memory
        case disks
        case diskIO = "disk_io"
        case proxy
        case batteries
        case thermal
        case bluetooth
        case network
        case topProcesses = "top_processes"
        case processAlerts = "process_alerts"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collectedAt = try container.decodeIfPresent(Date.self, forKey: .collectedAt)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)
        uptime = try container.decodeIfPresent(String.self, forKey: .uptime)
        healthScore = try container.decodeIfPresent(Int.self, forKey: .healthScore)
        healthScoreMessage = try container.decodeIfPresent(String.self, forKey: .healthScoreMessage)
        hardware = try container.decodeIfPresent(HardwareStatus.self, forKey: .hardware)
        cpu = try container.decodeIfPresent(CPUStatus.self, forKey: .cpu)
        gpu = try container.decodeIfPresent([GPUStatus].self, forKey: .gpu) ?? []
        memory = try container.decodeIfPresent(MemoryStatus.self, forKey: .memory)
        disks = try container.decodeIfPresent([DiskStatus].self, forKey: .disks) ?? []
        diskIO = try container.decodeIfPresent(DiskIOStatus.self, forKey: .diskIO)
        proxy = try container.decodeIfPresent(ProxyStatus.self, forKey: .proxy)
        batteries = try container.decodeIfPresent([BatteryStatus].self, forKey: .batteries) ?? []
        thermal = try container.decodeIfPresent(ThermalStatus.self, forKey: .thermal)
        bluetooth = try container.decodeIfPresent([BluetoothStatus].self, forKey: .bluetooth) ?? []
        network = try container.decodeIfPresent([NetworkStatus].self, forKey: .network) ?? []
        topProcesses = try container.decodeIfPresent([ProcessInfo].self, forKey: .topProcesses) ?? []
        processAlerts = try container.decodeIfPresent([ProcessAlert].self, forKey: .processAlerts) ?? []
    }
}

public struct HardwareStatus: Decodable, Equatable {
    public var model: String?
    public var cpuModel: String?
    public var totalRAM: String?
    public var diskSize: String?
    public var osVersion: String?
    public var refreshRate: String?

    enum CodingKeys: String, CodingKey {
        case model
        case cpuModel = "cpu_model"
        case totalRAM = "total_ram"
        case diskSize = "disk_size"
        case osVersion = "os_version"
        case refreshRate = "refresh_rate"
    }
}

public struct CPUStatus: Decodable, Equatable {
    public var usage: Double
    public var load1: Double?
    public var logicalCPU: Int?

    enum CodingKeys: String, CodingKey {
        case usage
        case load1
        case logicalCPU = "logical_cpu"
    }
}

public struct GPUStatus: Decodable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var usage: Double?
    public var memoryUsed: UInt64?
    public var memoryTotal: UInt64?
    public var coreCount: Int?
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case name
        case usage
        case memoryUsed = "memory_used"
        case memoryTotal = "memory_total"
        case coreCount = "core_count"
        case note
    }
}

public struct MemoryStatus: Decodable, Equatable {
    public var used: UInt64
    public var total: UInt64
    public var usedPercent: Double
    public var pressure: String?

    enum CodingKeys: String, CodingKey {
        case used
        case total
        case usedPercent = "used_percent"
        case pressure
    }
}

public struct DiskIOStatus: Decodable, Equatable {
    public var readRate: Double
    public var writeRate: Double

    enum CodingKeys: String, CodingKey {
        case readRate = "read_rate"
        case writeRate = "write_rate"
    }
}

public struct ProxyStatus: Decodable, Equatable {
    public var enabled: Bool
    public var type: String?
    public var host: String?
}

public struct DiskStatus: Decodable, Equatable, Identifiable {
    public var id: String { mount }
    public var mount: String
    public var device: String?
    public var used: UInt64
    public var total: UInt64
    public var usedPercent: Double
    public var external: Bool?

    enum CodingKeys: String, CodingKey {
        case mount
        case device
        case used
        case total
        case usedPercent = "used_percent"
        case external
    }
}

public struct ThermalStatus: Decodable, Equatable {
    public var cpuTemp: Double?
    public var gpuTemp: Double?
    public var batteryTemp: Double?
    public var fanSpeed: Double?
    public var fanCount: Int?
    public var systemPower: Double?
    public var adapterPower: Double?
    public var batteryPower: Double?

    enum CodingKeys: String, CodingKey {
        case cpuTemp = "cpu_temp"
        case gpuTemp = "gpu_temp"
        case batteryTemp = "battery_temp"
        case fanSpeed = "fan_speed"
        case fanCount = "fan_count"
        case systemPower = "system_power"
        case adapterPower = "adapter_power"
        case batteryPower = "battery_power"
    }
}

public struct BluetoothStatus: Decodable, Equatable, Identifiable {
    public var id: String { "\(name)-\(battery ?? "")" }
    public var name: String
    public var connected: Bool
    public var battery: String?
}

public struct BatteryStatus: Decodable, Equatable, Identifiable {
    public var id: String { "\(percent)-\(status ?? "")" }
    public var percent: Double
    public var status: String?
    public var health: String?
}

public struct NetworkStatus: Decodable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var rxRateMBs: Double
    public var txRateMBs: Double
    public var ip: String?

    enum CodingKeys: String, CodingKey {
        case name
        case rxRateMBs = "rx_rate_mbs"
        case txRateMBs = "tx_rate_mbs"
        case ip
    }
}

public struct ProcessInfo: Decodable, Equatable, Identifiable {
    public var id: Int { pid }
    public var pid: Int
    public var name: String
    public var command: String?
    public var cpu: Double
    public var memory: Double
}

public struct ProcessAlert: Decodable, Equatable, Identifiable {
    public var id: String { "\(pid)-\(name)-\(status)" }
    public var pid: Int
    public var name: String
    public var status: String
    public var cpu: Double?
}

public struct CleanupPreview: Decodable, Equatable {
    public var schemaVersion: Int
    public var command: String
    public var dryRun: Bool
    public var status: String
    public var estimatedBytes: Int64
    public var itemCount: Int
    public var categoryCount: Int
    public var skippedCount: Int
    public var protectedCount: Int
    public var whitelistCount: Int
    public var adminRequired: Bool
    public var deleteMode: String
    public var detailsPath: String
    public var categories: [CleanupCategory]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command
        case dryRun = "dry_run"
        case status
        case estimatedBytes = "estimated_bytes"
        case itemCount = "item_count"
        case categoryCount = "category_count"
        case skippedCount = "skipped_count"
        case protectedCount = "protected_count"
        case whitelistCount = "whitelist_count"
        case adminRequired = "admin_required"
        case deleteMode = "delete_mode"
        case detailsPath = "details_path"
        case categories
    }
}

public struct CleanupCategory: Decodable, Equatable, Identifiable {
    public var id: String { "\(section)-\(name)" }
    public var section: String
    public var name: String
    public var estimatedBytes: Int64
    public var itemCount: Int
    public var skippedCount: Int
    public var risk: String
    public var riskReason: String
    public var adminRequired: Bool

    enum CodingKeys: String, CodingKey {
        case section
        case name
        case estimatedBytes = "estimated_bytes"
        case itemCount = "item_count"
        case skippedCount = "skipped_count"
        case risk
        case riskReason = "risk_reason"
        case adminRequired = "admin_required"
    }
}

public struct ApplicationListResponse: Decodable, Equatable {
    public var schemaVersion: Int
    public var apps: [InstalledApplication]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case apps
    }
}

public struct InstalledApplication: Decodable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var bundleID: String
    public var source: String
    public var uninstallName: String
    public var path: String
    public var size: String

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case source
        case uninstallName = "uninstall_name"
        case path
        case size
    }
}

public struct StorageScan: Decodable, Equatable {
    public var path: String
    public var overview: Bool
    public var entries: [StorageEntry]
    public var largeFiles: [StorageFile]
    public var totalSize: Int64
    public var totalFiles: Int64?

    enum CodingKeys: String, CodingKey {
        case path
        case overview
        case entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        overview = try container.decode(Bool.self, forKey: .overview)
        entries = try container.decodeIfPresent([StorageEntry].self, forKey: .entries) ?? []
        largeFiles = try container.decodeIfPresent([StorageFile].self, forKey: .largeFiles) ?? []
        totalSize = try container.decode(Int64.self, forKey: .totalSize)
        totalFiles = try container.decodeIfPresent(Int64.self, forKey: .totalFiles)
    }
}

public struct StorageEntry: Decodable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var size: Int64
    public var isDir: Bool
    public var insight: Bool?
    public var cleanable: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case size
        case isDir = "is_dir"
        case insight
        case cleanable
    }
}

public struct StorageFile: Decodable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var size: Int64
}

public struct OptimizePreview: Decodable, Equatable {
    public var memoryUsedGB: Double
    public var memoryTotalGB: Double
    public var diskUsedGB: Double
    public var diskTotalGB: Double
    public var diskUsedPercent: Double
    public var uptimeDays: Double
    public var optimizations: [OptimizationTask]

    enum CodingKeys: String, CodingKey {
        case memoryUsedGB = "memory_used_gb"
        case memoryTotalGB = "memory_total_gb"
        case diskUsedGB = "disk_used_gb"
        case diskTotalGB = "disk_total_gb"
        case diskUsedPercent = "disk_used_percent"
        case uptimeDays = "uptime_days"
        case optimizations
    }
}

public struct OptimizationTask: Decodable, Equatable, Identifiable {
    public var id: String { action }
    public var category: String
    public var name: String
    public var description: String
    public var action: String
    public var safe: Bool
}

public struct PurgePreview: Decodable, Equatable {
    public var schemaVersion: Int
    public var command: String
    public var estimatedBytes: Int64
    public var itemCount: Int
    public var searchPaths: [String]
    public var items: [PurgeItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command
        case estimatedBytes = "estimated_bytes"
        case itemCount = "item_count"
        case searchPaths = "search_paths"
        case items
    }
}

public struct PurgeItem: Decodable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var projectRoot: String
    public var bytes: Int64
    public var recent: Bool
    public var ageDays: Int

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case projectRoot = "project_root"
        case bytes
        case recent
        case ageDays = "age_days"
    }
}

public struct InstallerPreview: Decodable, Equatable {
    public var schemaVersion: Int
    public var command: String
    public var estimatedBytes: Int64
    public var itemCount: Int
    public var items: [InstallerItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case command
        case estimatedBytes = "estimated_bytes"
        case itemCount = "item_count"
        case items
    }
}

public struct InstallerItem: Decodable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var source: String
    public var bytes: Int64
}

public struct WhitelistResponse: Decodable, Equatable {
    public var schemaVersion: Int
    public var mode: String
    public var items: [WhitelistItem]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case mode
        case items
    }
}

public struct WhitelistItem: Decodable, Equatable, Identifiable {
    public var id: String { pattern }
    public var name: String
    public var pattern: String
    public var category: String
    public var selected: Bool
}

public struct PurgePathsResponse: Decodable, Equatable {
    public var schemaVersion: Int
    public var configPath: String
    public var paths: [String]
    public var defaultPaths: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case configPath = "config_path"
        case paths
        case defaultPaths = "default_paths"
    }
}

public struct TouchIDStatus: Decodable, Equatable {
    public var schemaVersion: Int
    public var configured: Bool
    public var supported: Bool
    public var sudoFile: String
    public var sudoLocalFile: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case configured
        case supported
        case sudoFile = "sudo_file"
        case sudoLocalFile = "sudo_local_file"
    }
}

public struct CompletionStatus: Decodable, Equatable {
    public var schemaVersion: Int
    public var shell: String
    public var configFile: String
    public var installed: Bool
    public var commandName: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case shell
        case configFile = "config_file"
        case installed
        case commandName = "command_name"
    }
}

public struct MoleMaintenanceStatus: Decodable, Equatable {
    public var schemaVersion: Int
    public var version: String
    public var channel: String
    public var commit: String
    public var installMethod: String
    public var cliPath: String
    public var configPath: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case version
        case channel
        case commit
        case installMethod = "install_method"
        case cliPath = "cli_path"
        case configPath = "config_path"
    }
}

public struct LauncherStatus: Decodable, Equatable {
    public var schemaVersion: Int
    public var raycastDir: String
    public var raycastInstalled: Bool
    public var raycastCount: Int
    public var alfredDir: String
    public var alfredAvailable: Bool
    public var alfredInstalled: Bool
    public var alfredCount: Int
    public var commandCount: Int
    public var commands: [LauncherCommandStatus]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case raycastDir = "raycast_dir"
        case raycastInstalled = "raycast_installed"
        case raycastCount = "raycast_count"
        case alfredDir = "alfred_dir"
        case alfredAvailable = "alfred_available"
        case alfredInstalled = "alfred_installed"
        case alfredCount = "alfred_count"
        case commandCount = "command_count"
        case commands
    }
}

public struct LauncherCommandStatus: Decodable, Equatable, Identifiable {
    public var id: String { command }
    public var command: String
    public var title: String
    public var raycastInstalled: Bool
    public var alfredInstalled: Bool

    enum CodingKeys: String, CodingKey {
        case command
        case title
        case raycastInstalled = "raycast_installed"
        case alfredInstalled = "alfred_installed"
    }
}

public struct ExecutionPlan: Codable, Equatable {
    public var confirmed: Bool
    public var dryRun: Bool
    public var targets: [String]
    public var patterns: [String]
    public var paths: [String]
    public var externalPath: String?
    public var scanPath: String?
    public var operation: String?
    public var force: Bool?
    public var nightly: Bool?

    enum CodingKeys: String, CodingKey {
        case confirmed
        case dryRun = "dry_run"
        case targets
        case patterns
        case paths
        case externalPath = "external_path"
        case scanPath = "scan_path"
        case operation
        case force
        case nightly
    }

    public init(
        confirmed: Bool,
        dryRun: Bool = false,
        targets: [String] = [],
        patterns: [String] = [],
        paths: [String] = [],
        externalPath: String? = nil,
        scanPath: String? = nil,
        operation: String? = nil,
        force: Bool? = nil,
        nightly: Bool? = nil
    ) {
        self.confirmed = confirmed
        self.dryRun = dryRun
        self.targets = targets
        self.patterns = patterns
        self.paths = paths
        self.externalPath = externalPath
        self.scanPath = scanPath
        self.operation = operation
        self.force = force
        self.nightly = nightly
    }
}

public struct ExecutionEvent: Decodable, Equatable, Identifiable {
    public var id = UUID()
    public var event: String
    public var domain: String
    public var message: String?
    public var exitCode: Int?
    public var bytes: Int64?
    public var itemCount: Int?
    public var categoryCount: Int?
    public var freeSpace: String?
    public var equivalent: String?

    enum CodingKeys: String, CodingKey {
        case event
        case domain
        case message
        case exitCode = "exit_code"
        case bytes
        case itemCount = "item_count"
        case categoryCount = "category_count"
        case freeSpace = "free_space"
        case equivalent
    }
}
