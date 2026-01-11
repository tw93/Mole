import Foundation

// Swift structs matching the Go JSON structure
// Go uses PascalCase for JSON keys
struct MetricsSnapshot: Codable {
    let collectedAt: String
    let host: String
    let platform: String
    let uptime: String
    let procs: UInt64
    let hardware: HardwareInfo
    let healthScore: Int
    let healthScoreMsg: String
    let cpu: CPUStatus
    let gpu: [GPUStatus]
    let memory: MemoryStatus
    let disks: [DiskStatus]
    let diskIO: DiskIOStatus
    let network: [NetworkStatus]?
    let proxy: ProxyStatus
    let batteries: [BatteryStatus]
    let thermal: ThermalStatus
    let sensors: [SensorReading]?
    let bluetooth: [BluetoothDevice]
    let topProcesses: [ProcessInfo]

    enum CodingKeys: String, CodingKey {
        case collectedAt = "CollectedAt"
        case host = "Host"
        case platform = "Platform"
        case uptime = "Uptime"
        case procs = "Procs"
        case hardware = "Hardware"
        case healthScore = "HealthScore"
        case healthScoreMsg = "HealthScoreMsg"
        case cpu = "CPU"
        case gpu = "GPU"
        case memory = "Memory"
        case disks = "Disks"
        case diskIO = "DiskIO"
        case network = "Network"
        case proxy = "Proxy"
        case batteries = "Batteries"
        case thermal = "Thermal"
        case sensors = "Sensors"
        case bluetooth = "Bluetooth"
        case topProcesses = "TopProcesses"
    }
}

struct HardwareInfo: Codable {
    let model: String
    let cpuModel: String
    let totalRAM: String
    let diskSize: String
    let osVersion: String
    let refreshRate: String

    enum CodingKeys: String, CodingKey {
        case model = "Model"
        case cpuModel = "CPUModel"
        case totalRAM = "TotalRAM"
        case diskSize = "DiskSize"
        case osVersion = "OSVersion"
        case refreshRate = "RefreshRate"
    }
}

struct CPUStatus: Codable {
    let usage: Double
    let perCore: [Double]
    let perCoreEstimated: Bool
    let load1: Double
    let load5: Double
    let load15: Double
    let coreCount: Int
    let logicalCPU: Int
    let pCoreCount: Int
    let eCoreCount: Int

    enum CodingKeys: String, CodingKey {
        case usage = "Usage"
        case perCore = "PerCore"
        case perCoreEstimated = "PerCoreEstimated"
        case load1 = "Load1"
        case load5 = "Load5"
        case load15 = "Load15"
        case coreCount = "CoreCount"
        case logicalCPU = "LogicalCPU"
        case pCoreCount = "PCoreCount"
        case eCoreCount = "ECoreCount"
    }
}

struct GPUStatus: Codable {
    let name: String
    let usage: Double
    let memoryUsed: Double
    let memoryTotal: Double
    let coreCount: Int
    let note: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case usage = "Usage"
        case memoryUsed = "MemoryUsed"
        case memoryTotal = "MemoryTotal"
        case coreCount = "CoreCount"
        case note = "Note"
    }
}

struct MemoryStatus: Codable {
    let used: UInt64
    let total: UInt64
    let usedPercent: Double
    let swapUsed: UInt64
    let swapTotal: UInt64
    let cached: UInt64
    let pressure: String

    enum CodingKeys: String, CodingKey {
        case used = "Used"
        case total = "Total"
        case usedPercent = "UsedPercent"
        case swapUsed = "SwapUsed"
        case swapTotal = "SwapTotal"
        case cached = "Cached"
        case pressure = "Pressure"
    }
}

struct DiskStatus: Codable {
    let mount: String
    let device: String
    let used: UInt64
    let total: UInt64
    let usedPercent: Double
    let fstype: String
    let external: Bool

    enum CodingKeys: String, CodingKey {
        case mount = "Mount"
        case device = "Device"
        case used = "Used"
        case total = "Total"
        case usedPercent = "UsedPercent"
        case fstype = "Fstype"
        case external = "External"
    }
}

struct DiskIOStatus: Codable {
    let readRate: Double
    let writeRate: Double

    enum CodingKeys: String, CodingKey {
        case readRate = "ReadRate"
        case writeRate = "WriteRate"
    }
}

struct NetworkStatus: Codable {
    let name: String
    let rxRateMBs: Double
    let txRateMBs: Double
    let ip: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case rxRateMBs = "RxRateMBs"
        case txRateMBs = "TxRateMBs"
        case ip = "IP"
    }
}

struct ProxyStatus: Codable {
    let enabled: Bool
    let type: String
    let host: String

    enum CodingKeys: String, CodingKey {
        case enabled = "Enabled"
        case type = "Type"
        case host = "Host"
    }
}

struct BatteryStatus: Codable {
    let percent: Double
    let status: String
    let timeLeft: String
    let health: String
    let cycleCount: Int
    let capacity: Int

    enum CodingKeys: String, CodingKey {
        case percent = "Percent"
        case status = "Status"
        case timeLeft = "TimeLeft"
        case health = "Health"
        case cycleCount = "CycleCount"
        case capacity = "Capacity"
    }
}

struct ThermalStatus: Codable {
    let cpuTemp: Double
    let gpuTemp: Double
    let fanSpeed: Int
    let fanCount: Int
    let systemPower: Double
    let adapterPower: Double
    let batteryPower: Double

    enum CodingKeys: String, CodingKey {
        case cpuTemp = "CPUTemp"
        case gpuTemp = "GPUTemp"
        case fanSpeed = "FanSpeed"
        case fanCount = "FanCount"
        case systemPower = "SystemPower"
        case adapterPower = "AdapterPower"
        case batteryPower = "BatteryPower"
    }
}

struct SensorReading: Codable {
    let label: String
    let value: Double
    let unit: String
    let note: String

    enum CodingKeys: String, CodingKey {
        case label = "Label"
        case value = "Value"
        case unit = "Unit"
        case note = "Note"
    }
}

struct BluetoothDevice: Codable {
    let name: String
    let connected: Bool
    let battery: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case connected = "Connected"
        case battery = "Battery"
    }
}

struct ProcessInfo: Codable {
    let name: String
    let cpu: Double
    let memory: Double

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case cpu = "CPU"
        case memory = "Memory"
    }
}

class MetricsManager {
    private var initialized = false

    func initialize() {
        guard !initialized else {
            print("MetricsManager: Already initialized")
            return
        }

        print("MetricsManager: Calling InitMetrics()...")
        // Call the C function InitMetrics from the dylib
        guard let result = InitMetrics() else {
            print("MetricsManager: InitMetrics returned nil!")
            return
        }

        defer { FreeString(result) }

        let str = String(cString: result)
        print("MetricsManager: InitMetrics returned: '\(str)'")

        if str == "OK" {
            initialized = true
            print("Metrics collector initialized successfully")
        } else {
            print("Failed to initialize metrics collector: \(str)")
        }
    }

    func getMetrics() -> MetricsSnapshot? {
        guard initialized else {
            print("MetricsManager: Metrics manager not initialized")
            return nil
        }

        // Call the C function GetMetricsJSON from the dylib
        print("MetricsManager: Calling GetMetricsJSON()...")
        guard let jsonCString = GetMetricsJSON() else {
            print("MetricsManager: GetMetricsJSON() returned nil")
            return nil
        }

        defer { FreeString(jsonCString) }

        let jsonString = String(cString: jsonCString)
        print("MetricsManager: Got JSON response (\(jsonString.count) chars)")

        // Check for error in JSON
        if jsonString.contains("\"error\"") {
            print("MetricsManager: Error in JSON: \(jsonString)")
            return nil
        }

        // Parse JSON
        guard let jsonData = jsonString.data(using: .utf8) else {
            print("MetricsManager: Failed to convert JSON string to data")
            return nil
        }

        do {
            let decoder = JSONDecoder()
            let snapshot = try decoder.decode(MetricsSnapshot.self, from: jsonData)
            print("MetricsManager: Successfully decoded metrics - CPU: \(snapshot.cpu.usage)%")
            return snapshot
        } catch {
            print("MetricsManager: Failed to decode JSON: \(error)")
            print("MetricsManager: First 500 chars of JSON: \(String(jsonString.prefix(500)))")
            return nil
        }
    }

    func cleanup() {
        guard initialized else { return }
        CleanupMetrics()
        initialized = false
    }
}
