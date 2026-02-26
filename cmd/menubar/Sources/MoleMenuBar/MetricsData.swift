import Foundation

// MARK: - JSON models matching Go's MetricsSnapshot

struct MetricsSnapshot: Codable {
    let CollectedAt: String?
    let Host: String?
    let Uptime: String?
    let Hardware: HardwareInfo?
    let HealthScore: Int?
    let HealthScoreMsg: String?
    let CPU: CPUStatus?
    let GPU: [GPUStatus]?
    let Memory: MemoryStatus?
    let Disks: [DiskStatus]?
    let DiskIO: DiskIOStatus?
    let Batteries: [BatteryStatus]?
    let Thermal: ThermalStatus?
    let TopProcesses: [MoleProcessInfo]?
    let Network: [NetworkStatus]?
    let Proxy: ProxyStatus?
}

struct HardwareInfo: Codable {
    let Model: String?
    let CPUModel: String?
    let TotalRAM: String?
    let DiskSize: String?
    let OSVersion: String?
    let RefreshRate: String?
}

struct CPUStatus: Codable {
    let Usage: Double?
    let Load1: Double?
    let Load5: Double?
    let Load15: Double?
    let CoreCount: Int?
    let LogicalCPU: Int?
    let PCoreCount: Int?
    let ECoreCount: Int?
}

struct GPUStatus: Codable {
    let Name: String?
    let CoreCount: Int?
}

struct MemoryStatus: Codable {
    let Used: UInt64?
    let Total: UInt64?
    let UsedPercent: Double?
    let SwapUsed: UInt64?
    let SwapTotal: UInt64?
    let Pressure: String?
}
struct DiskStatus: Codable {
    let Mount: String?
    let Used: UInt64?
    let Total: UInt64?
    let UsedPercent: Double?
    let External: Bool?
}

struct DiskIOStatus: Codable {
    let ReadRate: Double?
    let WriteRate: Double?
}

struct BatteryStatus: Codable {
    let Percent: Double?
    let Status: String?
    let TimeLeft: String?
    let Health: String?
    let CycleCount: Int?
    let Capacity: Int?
}

struct ThermalStatus: Codable {
    let CPUTemp: Double?
    let FanSpeed: Int?
    let SystemPower: Double?
    let AdapterPower: Double?
    let BatteryPower: Double?
}

struct MoleProcessInfo: Codable {
    let Name: String?
    let CPU: Double?
    let Memory: Double?
}

struct NetworkStatus: Codable {
    let Name: String?
    let RxRateMBs: Double?
    let TxRateMBs: Double?
    let IP: String?
}

struct ProxyStatus: Codable {
    let Enabled: Bool?
    let `Type`: String?
    let Host: String?
}

// MARK: - Formatting helpers

/// Matches Go's metrics.FormatRate() exactly.
func formatRate(_ mb: Double) -> String {
    if mb < 0.01 { return "0 MB/s" }
    if mb < 1 { return String(format: "%.2f MB/s", mb) }
    if mb < 10 { return String(format: "%.1f MB/s", mb) }
    return String(format: "%.0f MB/s", mb)
}

func humanBytes(_ v: UInt64) -> String {
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

func humanBytesShort(_ v: UInt64) -> String {
    let gb = UInt64(1) << 30
    let mb = UInt64(1) << 20
    switch v {
    case gb...: return String(format: "%.0fG", Double(v) / Double(gb))
    case mb...: return String(format: "%.0fM", Double(v) / Double(mb))
    default: return "\(v)"
    }
}
