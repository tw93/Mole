import Foundation

// MARK: - JSON models matching Go's MetricsSnapshot

public struct MetricsSnapshot: Codable {
    public let CollectedAt: String?
    public let Host: String?
    public let Uptime: String?
    public let Hardware: HardwareInfo?
    public let HealthScore: Int?
    public let HealthScoreMsg: String?
    public let CPU: CPUStatus?
    public let GPU: [GPUStatus]?
    public let Memory: MemoryStatus?
    public let Disks: [DiskStatus]?
    public let DiskIO: DiskIOStatus?
    public let Batteries: [BatteryStatus]?
    public let Thermal: ThermalStatus?
    public let TopProcesses: [MoleProcessInfo]?
    public let Network: [NetworkStatus]?
    public let Proxy: ProxyStatus?
}

public struct HardwareInfo: Codable {
    public let Model: String?
    public let CPUModel: String?
    public let TotalRAM: String?
    public let DiskSize: String?
    public let OSVersion: String?
    public let RefreshRate: String?
}

public struct CPUStatus: Codable {
    public let Usage: Double?
    public let Load1: Double?
    public let Load5: Double?
    public let Load15: Double?
    public let CoreCount: Int?
    public let LogicalCPU: Int?
    public let PCoreCount: Int?
    public let ECoreCount: Int?
}

public struct GPUStatus: Codable {
    public let Name: String?
    public let CoreCount: Int?
}

public struct MemoryStatus: Codable {
    public let Used: UInt64?
    public let Total: UInt64?
    public let UsedPercent: Double?
    public let SwapUsed: UInt64?
    public let SwapTotal: UInt64?
    public let Pressure: String?
}

public struct DiskStatus: Codable {
    public let Mount: String?
    public let Used: UInt64?
    public let Total: UInt64?
    public let UsedPercent: Double?
    public let External: Bool?
}

public struct DiskIOStatus: Codable {
    public let ReadRate: Double?
    public let WriteRate: Double?
}

public struct BatteryStatus: Codable {
    public let Percent: Double?
    public let Status: String?
    public let TimeLeft: String?
    public let Health: String?
    public let CycleCount: Int?
    public let Capacity: Int?
}

public struct ThermalStatus: Codable {
    public let CPUTemp: Double?
    public let FanSpeed: Int?
    public let SystemPower: Double?
    public let AdapterPower: Double?
    public let BatteryPower: Double?
}

public struct MoleProcessInfo: Codable {
    public let Name: String?
    public let CPU: Double?
    public let Memory: Double?
}

public struct NetworkStatus: Codable {
    public let Name: String?
    public let RxRateMBs: Double?
    public let TxRateMBs: Double?
    public let IP: String?
}

public struct ProxyStatus: Codable {
    public let Enabled: Bool?
    public let `Type`: String?
    public let Host: String?
}

// MARK: - Formatting helpers

/// Matches Go's metrics.FormatRate() exactly.
public func formatRate(_ mb: Double) -> String {
    if mb < 0.01 { return "0 MB/s" }
    if mb < 1 { return String(format: "%.2f MB/s", mb) }
    if mb < 10 { return String(format: "%.1f MB/s", mb) }
    return String(format: "%.0f MB/s", mb)
}

public func humanBytes(_ v: UInt64) -> String {
    let tb = UInt64(1) << 40
    let gb = UInt64(1) << 30
    let mb = UInt64(1) << 20
    switch v {
    case tb...: return String(format: "%.1f TB", Double(v) / Double(tb))
    case gb...: return String(format: "%.1f GB", Double(v) / Double(gb))
    case mb...: return String(format: "%.1f MB", Double(v) / Double(mb))
    default: return "\(v) B"
    }
}

public func humanBytesShort(_ v: UInt64) -> String {
    let gb = UInt64(1) << 30
    let mb = UInt64(1) << 20
    switch v {
    case gb...: return String(format: "%.0fG", Double(v) / Double(gb))
    case mb...: return String(format: "%.0fM", Double(v) / Double(mb))
    default: return "\(v)"
    }
}
