//
//  WidgetDataManager.swift
//  Tonic
//
//  Central data manager for menu bar widgets
//  Task ID: fn-2.2
//

import Foundation
import IOKit.ps
import IOKit
import CoreWLAN

// MARK: - Widget Data Models

/// CPU usage data for widgets
public struct CPUData: Sendable {
    public let totalUsage: Double
    public let perCoreUsage: [Double]
    public let timestamp: Date

    public init(totalUsage: Double, perCoreUsage: [Double], timestamp: Date = Date()) {
        self.totalUsage = totalUsage
        self.perCoreUsage = perCoreUsage
        self.timestamp = timestamp
    }
}

/// Memory usage data for widgets
public struct MemoryData: Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let pressure: MemoryPressure
    public let compressedBytes: UInt64
    public let swapBytes: UInt64
    public let timestamp: Date

    public init(usedBytes: UInt64, totalBytes: UInt64, pressure: MemoryPressure,
                compressedBytes: UInt64 = 0, swapBytes: UInt64 = 0, timestamp: Date = Date()) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.pressure = pressure
        self.compressedBytes = compressedBytes
        self.swapBytes = swapBytes
        self.timestamp = timestamp
    }

    public var usagePercentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }
}

/// Disk volume data for widgets
public struct DiskVolumeData: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let path: String
    public let usedBytes: UInt64
    public let totalBytes: UInt64
    public let isBootVolume: Bool
    public let isInternal: Bool
    public let isActive: Bool
    public let timestamp: Date

    public init(name: String, path: String, usedBytes: UInt64, totalBytes: UInt64,
                isBootVolume: Bool = false, isInternal: Bool = true, isActive: Bool = false, timestamp: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.isBootVolume = isBootVolume
        self.isInternal = isInternal
        self.isActive = isActive
        self.timestamp = timestamp
    }

    public var usagePercentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    public var freeBytes: UInt64 {
        max(0, totalBytes - usedBytes)
    }
}

/// Network data for widgets
public struct NetworkData: Sendable {
    public let uploadBytesPerSecond: Double
    public let downloadBytesPerSecond: Double
    public let isConnected: Bool
    public let connectionType: ConnectionType
    public let ssid: String?
    public let ipAddress: String?
    public let timestamp: Date

    public init(uploadBytesPerSecond: Double, downloadBytesPerSecond: Double,
                isConnected: Bool, connectionType: ConnectionType = .unknown,
                ssid: String? = nil, ipAddress: String? = nil, timestamp: Date = Date()) {
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.isConnected = isConnected
        self.connectionType = connectionType
        self.ssid = ssid
        self.ipAddress = ipAddress
        self.timestamp = timestamp
    }

    public var uploadMbps: Double {
        uploadBytesPerSecond * 8 / 1_000_000
    }

    public var downloadMbps: Double {
        downloadBytesPerSecond * 8 / 1_000_000
    }

    public var uploadString: String {
        formatBytes(uploadBytesPerSecond)
    }

    public var downloadString: String {
        formatBytes(downloadBytesPerSecond)
    }

    private func formatBytes(_ bytes: Double) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB/s", bytes / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.1f KB/s", bytes / 1_000)
        } else {
            return String(format: "%.0f B/s", bytes)
        }
    }
}

/// Network connection type
public enum ConnectionType: String, Sendable {
    case wifi
    case ethernet
    case cellular
    case unknown
}

/// GPU data for widgets (Apple Silicon only)
public struct GPUData: Sendable {
    public let usagePercentage: Double?
    public let usedMemory: UInt64?
    public let totalMemory: UInt64?
    public let temperature: Double? // Celsius
    public let timestamp: Date

    public init(usagePercentage: Double? = nil, usedMemory: UInt64? = nil,
                totalMemory: UInt64? = nil, temperature: Double? = nil, timestamp: Date = Date()) {
        self.usagePercentage = usagePercentage
        self.usedMemory = usedMemory
        self.totalMemory = totalMemory
        self.temperature = temperature
        self.timestamp = timestamp
    }

    public var memoryUsagePercentage: Double? {
        guard let used = usedMemory, let total = totalMemory, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
}

/// Battery data for widgets
public struct BatteryData: Sendable {
    public let isPresent: Bool
    public let isCharging: Bool
    public let isCharged: Bool
    public let chargePercentage: Double
    public let estimatedMinutesRemaining: Int?
    public let health: BatteryHealth
    public let timestamp: Date

    public init(isPresent: Bool, isCharging: Bool = false, isCharged: Bool = false,
                chargePercentage: Double = 0, estimatedMinutesRemaining: Int? = nil,
                health: BatteryHealth = .unknown, timestamp: Date = Date()) {
        self.isPresent = isPresent
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.chargePercentage = chargePercentage
        self.estimatedMinutesRemaining = estimatedMinutesRemaining
        self.health = health
        self.timestamp = timestamp
    }
}

/// App resource usage
public struct AppResourceUsage: Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let bundleIdentifier: String?
    public let icon: NSImage?
    public let cpuUsage: Double
    public let memoryBytes: UInt64
    public let timestamp: Date

    public init(name: String, bundleIdentifier: String? = nil, icon: NSImage? = nil,
                cpuUsage: Double = 0, memoryBytes: UInt64 = 0, timestamp: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
        self.cpuUsage = cpuUsage
        self.memoryBytes = memoryBytes
        self.timestamp = timestamp
    }

    public var memoryString: String {
        ByteCountFormatter.string(fromByteCount: Int64(memoryBytes), countStyle: .memory)
    }
}

// MARK: - Widget Data Manager

/// Central data manager that aggregates and distributes system monitoring data to widgets
@MainActor
@Observable
public final class WidgetDataManager {
    public static let shared = WidgetDataManager()

    // MARK: - History Constants

    private static let maxHistoryPoints = 60

    // MARK: - CPU Data

    public private(set) var cpuData: CPUData = CPUData(totalUsage: 0, perCoreUsage: [])
    public private(set) var cpuHistory: [Double] = []
    public private(set) var topCPUApps: [AppResourceUsage] = []

    // MARK: - Memory Data

    public private(set) var memoryData: MemoryData = MemoryData(
        usedBytes: 0, totalBytes: 0, pressure: .normal
    )
    public private(set) var memoryHistory: [Double] = []
    public private(set) var topMemoryApps: [AppResourceUsage] = []

    // MARK: - Disk Data

    public private(set) var diskVolumes: [DiskVolumeData] = []
    public private(set) var primaryDiskActivity: Bool = false

    // MARK: - Network Data

    public private(set) var networkData: NetworkData = NetworkData(
        uploadBytesPerSecond: 0, downloadBytesPerSecond: 0, isConnected: false
    )
    public private(set) var networkUploadHistory: [Double] = []
    public private(set) var networkDownloadHistory: [Double] = []

    // MARK: - GPU Data

    public private(set) var gpuData: GPUData = GPUData()

    // MARK: - Battery Data

    public private(set) var batteryData: BatteryData = BatteryData(isPresent: false)

    // MARK: - Monitoring State

    public private(set) var isMonitoring = false

    // MARK: - Private Properties

    private var updateTimer: DispatchSourceTimer?
    private var lastNetworkStats: (upload: UInt64, download: UInt64, timestamp: Date)?
    private var lastDiskReadBytes: UInt64 = 0
    private var lastDiskWriteBytes: UInt64 = 0

    // CPU tracking for delta calculation
    private var previousCPUInfo: processor_info_array_t?
    private var previousNumCpuInfo: mach_msg_type_number_t = 0
    private var previousNumCPUs: UInt32 = 0
    private let cpuLock = NSLock()

    // MARK: - Initialization

    private init() {}

    // MARK: - Public Methods

    /// Start monitoring system data
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let interval = WidgetPreferences.shared.updateInterval.timeInterval
        updateTimer = DispatchSource.makeTimerSource(queue: .main)
        updateTimer?.schedule(deadline: .now(), repeating: .seconds(Int(interval)))
        updateTimer?.setEventHandler { [weak self] in
            self?.updateAllData()
        }
        updateTimer?.resume()

        // Initial update
        updateAllData()
    }

    /// Stop monitoring system data
    public func stopMonitoring() {
        isMonitoring = false
        updateTimer?.cancel()
        updateTimer = nil
    }

    /// Update the monitoring interval based on preferences
    public func updateInterval() {
        if isMonitoring {
            stopMonitoring()
            startMonitoring()
        }
    }

    // MARK: - Data Updates

    private func updateAllData() {
        updateCPUData()
        updateMemoryData()
        updateDiskData()
        updateNetworkData()
        updateGPUData()
        updateBatteryData()

        // Update top apps less frequently (every 5th update)
        // This avoids the performance cost of querying all processes
        // topCPUApps and topMemoryApps will be updated separately
    }

    // MARK: - CPU Monitoring

    private func updateCPUData() {
        let usage = getCPUUsage()
        let perCore = getPerCoreCPUUsage()

        cpuData = CPUData(totalUsage: usage, perCoreUsage: perCore)

        // Update history
        addToHistory(&cpuHistory, value: usage, maxPoints: Self.maxHistoryPoints)
    }

    private func getCPUUsage() -> Double {
        var numCPUs: UInt32 = 0
        var numCpuInfo: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        var numTotalCpu: UInt32 = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numTotalCpu,
            &cpuInfo,
            &numCpuInfo
        )

        guard result == KERN_SUCCESS else { return 0 }

        cpuLock.lock()
        defer { cpuLock.unlock() }

        var usage = 0.0

        if let prevInfo = previousCPUInfo, previousNumCPUs > 0 {
            let prevUser = prevInfo[Int(CPU_STATE_USER)]
            let prevSystem = prevInfo[Int(CPU_STATE_SYSTEM)]
            let prevIdle = prevInfo[Int(CPU_STATE_IDLE)]
            let prevNice = prevInfo[Int(CPU_STATE_NICE)]

            let currentUser = cpuInfo?[Int(CPU_STATE_USER)] ?? 0
            let currentSystem = cpuInfo?[Int(CPU_STATE_SYSTEM)] ?? 0
            let currentIdle = cpuInfo?[Int(CPU_STATE_IDLE)] ?? 0
            let currentNice = cpuInfo?[Int(CPU_STATE_NICE)] ?? 0

            let prevTotal = prevUser + prevSystem + prevIdle + prevNice
            let currentTotal = currentUser + currentSystem + currentIdle + currentNice

            let diffTotal = currentTotal - prevTotal
            let diffIdle = currentIdle - prevIdle

            if diffTotal > 0 {
                usage = (1.0 - Double(diffIdle) / Double(diffTotal)) * 100.0
            }
        }

        // Store current for next iteration
        if let prevInfo = previousCPUInfo {
            vm_deallocate(
                mach_task_self(),
                vm_address_t(UInt(bitPattern: prevInfo)),
                vm_size_t(Int(previousNumCpuInfo) * MemoryLayout<integer_t>.size)
            )
        }

        previousCPUInfo = cpuInfo
        previousNumCpuInfo = numCpuInfo
        previousNumCPUs = numTotalCpu

        return max(0, min(100, usage))
    }

    private func getPerCoreCPUUsage() -> [Double] {
        var coreUsages: [Double] = []
        var numCPUs: UInt32 = 0
        var numCpuInfo: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        var numTotalCpu: UInt32 = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numTotalCpu,
            &cpuInfo,
            &numCpuInfo
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else {
            return []
        }

        let CPU_STATE_MAX = 4
        for i in 0..<Int(numTotalCpu) {
            let base = i * Int(CPU_STATE_MAX)

            let user = UInt32(info[base + Int(CPU_STATE_USER)])
            let system = UInt32(info[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(info[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(info[base + Int(CPU_STATE_NICE)])

            let total = user + system + idle + nice
            let usage = total > 0 ? Double(user + system) / Double(total) * 100.0 : 0.0
            coreUsages.append(max(0, min(100, usage)))
        }

        return coreUsages
    }

    // MARK: - Memory Monitoring

    private func updateMemoryData() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            memoryData = MemoryData(usedBytes: 0, totalBytes: 0, pressure: .normal)
            return
        }

        let pageSize = UInt64(vm_kernel_page_size)

        // Calculate memory usage
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        // Get physical memory
        var memSize: Int = 0
        var memSizeLen = MemoryLayout<Int>.size
        sysctlbyname("hw.memsize", &memSize, &memSizeLen, nil, 0)

        // Get swap usage
        var xswUsage: xsw_usage = xsw_usage()
        var xswSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &xswUsage, &xswSize, nil, 0) == 0 {
            // Swap available in xswUsage
        }

        // Calculate memory pressure
        let free = UInt64(stats.free_count) * pageSize
        let total = UInt64(stats.wire_count + stats.active_count + stats.inactive_count + stats.free_count) * pageSize
        let freePercentage = total > 0 ? Double(free) / Double(total) : 0

        let pressure: MemoryPressure
        if freePercentage < 0.05 {
            pressure = .critical
        } else if freePercentage < 0.15 {
            pressure = .warning
        } else {
            pressure = .normal
        }

        let swapBytes = UInt64(xswUsage.xsu_used)

        memoryData = MemoryData(
            usedBytes: used,
            totalBytes: UInt64(memSize),
            pressure: pressure,
            compressedBytes: compressed,
            swapBytes: swapBytes
        )

        // Update history
        addToHistory(&memoryHistory, value: memoryData.usagePercentage, maxPoints: Self.maxHistoryPoints)
    }

    // MARK: - Disk Monitoring

    private func updateDiskData() {
        var volumes: [DiskVolumeData] = []

        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRootFileSystemKey,
            .volumeIsInternalKey
        ]

        if let volumesURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys) {
            for url in volumesURLs {
                guard let resourceValues = try? url.resourceValues(forKeys: Set(keys)),
                      let name = resourceValues.volumeName,
                      let total = resourceValues.volumeTotalCapacity,
                      let available = resourceValues.volumeAvailableCapacity else {
                    continue
                }

                let used = total - available
                let isBoot = resourceValues.volumeIsRootFileSystem ?? false
                let isInternal = resourceValues.volumeIsInternal ?? true

                volumes.append(DiskVolumeData(
                    name: name,
                    path: url.path,
                    usedBytes: UInt64(used),
                    totalBytes: UInt64(total),
                    isBootVolume: isBoot,
                    isInternal: isInternal,
                    isActive: false
                ))
            }
        }

        // Sort: boot volume first, then by used bytes
        volumes.sort { $0.isBootVolume && !$1.isBootVolume || ($0.isBootVolume == $1.isBootVolume && $0.usedBytes > $1.usedBytes) }

        diskVolumes = volumes

        // Get disk I/O statistics using IOKit
        let (readBytes, writeBytes) = getDiskIOStatistics()
        primaryDiskActivity = (readBytes != lastDiskReadBytes || writeBytes != lastDiskWriteBytes)
        lastDiskReadBytes = readBytes
        lastDiskWriteBytes = writeBytes
    }

    /// Get system-wide disk I/O statistics using IOKit
    private func getDiskIOStatistics() -> (readBytes: UInt64, writeBytes: UInt64) {
        var totalReadBytes: UInt64 = 0
        var totalWriteBytes: UInt64 = 0

        // Match IOKit services for block storage drivers
        let matchingDict = IOServiceMatching(kIOBlockStorageDriverClass)
        guard let serviceIterator = IOServiceGetMatchingServices(kIOMasterPortDefault, matchingDict) else {
            return (0, 0)
        }

        var service: io_service_t?
        while case let nextService = IOIteratorNext(serviceIterator), nextService != 0 {
            service = nextService

            // Get statistics properties from the driver
            guard let properties = IORegistryEntryCreateCFProperty(service, kIOPropertyPlaneKey, kCFAllocatorDefault, 0).takeRetainedValue() as? [String: Any] else {
                continue
            }

            // Extract statistics (keys may vary by macOS version)
            if let stats = properties[kIOBlockStorageDriverStatisticsKey] as? [String: Any] {
                if let readBytes = stats[kIOBlockStorageDriverStatisticsBytesReadKey] as? UInt64 {
                    totalReadBytes += readBytes
                }
                if let writeBytes = stats[kIOBlockStorageDriverStatisticsBytesWrittenKey] as? UInt64 {
                    totalWriteBytes += writeBytes
                }
            }

            IOObjectRelease(service)
        }

        IOObjectRelease(serviceIterator)

        return (totalReadBytes, totalWriteBytes)
    }

    // MARK: - Network Monitoring

    private struct NetworkStats {
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    private func updateNetworkData() {
        let stats = getNetworkStats()
        let now = Date()

        var uploadRate: Double = 0
        var downloadRate: Double = 0
        var isConnected = true

        if let last = lastNetworkStats {
            let timeDelta = now.timeIntervalSince(last.timestamp)

            if timeDelta > 0 {
                uploadRate = Double(stats.bytesOut - last.upload) / timeDelta
                downloadRate = Double(stats.bytesIn - last.download) / timeDelta
            }

            isConnected = (stats.bytesIn != last.download || stats.bytesOut != last.upload) || timeDelta < 5.0
        }

        lastNetworkStats = (upload: stats.bytesOut, download: stats.bytesIn, timestamp: now)

        // Get connection info
        let connectionType = getConnectionType()
        let ssid = getWiFiSSID()

        networkData = NetworkData(
            uploadBytesPerSecond: max(0, uploadRate),
            downloadBytesPerSecond: max(0, downloadRate),
            isConnected: isConnected,
            connectionType: connectionType,
            ssid: ssid
        )

        // Update history
        addToHistory(&networkUploadHistory, value: uploadRate / 1024, maxPoints: Self.maxHistoryPoints) // KB/s
        addToHistory(&networkDownloadHistory, value: downloadRate / 1024, maxPoints: Self.maxHistoryPoints)
    }

    private func getNetworkStats() -> NetworkStats {
        var totalBytesIn: UInt64 = 0
        var totalBytesOut: UInt64 = 0

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_IFLIST2]
        var len: Int = 0

        sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0)

        var buffer = [Int8](repeating: 0, count: len)
        sysctl(&mib, UInt32(mib.count), &buffer, &len, nil, 0)

        let pointer = buffer.withUnsafeBytes { $0.baseAddress?.assumingMemoryBound(to: if_msghdr2.self) }

        var offset = 0
        while offset < len {
            guard let ifm = pointer?.advanced(by: offset).pointee else { break }

            if ifm.ifm_type == RTM_IFINFO2 {
                let ifData = pointer?.advanced(by: offset + MemoryLayout<if_msghdr2>.stride).withMemoryRebound(to: if_data64.self, capacity: 1) {
                    $0.pointee
                }

                if let data = ifData {
                    totalBytesIn += data.ifi_ibytes
                    totalBytesOut += data.ifi_obytes
                }
            }

            offset += Int(ifm.ifm_msglen)
        }

        return NetworkStats(bytesIn: totalBytesIn, bytesOut: totalBytesOut)
    }

    private func getConnectionType() -> ConnectionType {
        // Use CoreWLAN to detect connection type
        if let client = CWWiFiClient.shared(),
           let interface = client.interfaces()?.first,
           interface.powerOn {
            // WiFi is on and connected
            if interface.ssid() != nil {
                return .wifi
            }
        }

        // Check if we have any network connectivity (fallback to ethernet/other)
        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let firstAddr = ifaddrs else {
            return .unknown
        }

        defer { freeifaddrs(ifaddrs) }

        var hasEthernet = false
        var ptr = firstAddr
        while ptr != nil {
            let interface = String(cString: ptr.pointee.ifa_name)
            let addrFamily = ptr.pointee.ifa_addr.pointee.sa_family

            // Check for active ethernet interfaces (en0, en1, etc.)
            if addrFamily == UInt8(AF_INET) || addrFamily == UInt8(AF_INET6) {
                if interface.hasPrefix("en") && interface != "en0" {
                    // en0 is typically WiFi on macOS, other en* are ethernet
                    hasEthernet = true
                }
            }

            ptr = ptr.pointee.ifa_next
        }

        return hasEthernet ? .ethernet : .other
    }

    private func getWiFiInterface() -> String? {
        // Use CoreWLAN to get WiFi interface name
        if let client = CWWiFiClient.shared(),
           let interface = client.interfaces()?.first,
           interface.powerOn {
            return interface.interfaceName
        }
        return nil
    }

    private func getWiFiSSID() -> String? {
        // Use CoreWLAN to get the current SSID
        // Note: This requires the app to have the "com.apple.security.network.client" entitlement
        // or be run without sandboxing (like a menu bar app)
        if let client = CWWiFiClient.shared(),
           let interface = client.interfaces()?.first,
           interface.powerOn {
            return interface.ssid()
        }
        return nil
    }

    // MARK: - GPU Monitoring

    private func updateGPUData() {
        #if arch(arm64)
        // Apple Silicon GPU monitoring
        var usage: Double? = nil
        var usedMemory: UInt64? = nil
        var totalMemory: UInt64? = nil
        var temperature: Double? = nil

        // Get total unified memory available to GPU
        if let physMemory = getPhysicalMemory() {
            // On Apple Silicon, GPU can access all unified memory
            // Reserve some for system (typically 2-3GB)
            let gpuAccessibleMemory = physMemory - (2 * 1024 * 1024 * 1024) // Reserve 2GB
            totalMemory = gpuAccessibleMemory
        }

        // Try to get GPU activity from IORegistry
        // Apple AGX GPU registers under IOService:/AppleARMIODevice/AGX
        if let gpuService = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOGPU")) {
            // Try to read GPU stats
            if let properties = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                // Parse GPU stats if available
                if let activity = properties["ActivityLevel"] as? Double {
                    usage = activity * 100
                }
            }
            IOObjectRelease(gpuService)
        }

        // Alternative: Try IOAccelerator
        if usage == nil {
            var iterator: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
                var service: io_object_t
                while (service = IOIteratorNext(iterator)), service != 0 {
                    // Check if this is an Apple GPU
                    if let name = IORegistryEntryCreateCFProperty(service, "IOName" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       name.contains("AGX") || name.contains("AppleGPU") {
                        // Found Apple Silicon GPU
                        // Try to get performance statistics
                        if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                            if let activity = stats["DeviceUtilization"] as? Double {
                                usage = activity * 100
                            }
                        }
                    }
                    IOObjectRelease(service)
                }
                IOObjectRelease(iterator)
            }
        }

        // Try to get GPU temperature from IOPM (power management)
        if let thermals = getThermalInfo() {
            temperature = thermals.gpuTemperature
        }

        // Estimate GPU memory usage from system memory pressure
        // On unified memory, GPU + CPU share the same pool
        // GPU typically uses 5-15% when idle, up to 50%+ under load
        if let total = totalMemory, let memPercent = memoryData.usagePercentage {
            // Estimate GPU memory based on activity and system memory pressure
            // This is an approximation since Apple doesn't expose exact GPU memory allocation
            let estimatedGPUMemoryPercent = usage ?? 10.0 // Default 10% idle
            usedMemory = UInt64(Double(total) * (estimatedGPUMemoryPercent / 100.0))
        }

        gpuData = GPUData(
            usagePercentage: usage,
            usedMemory: usedMemory,
            totalMemory: totalMemory,
            temperature: temperature,
            timestamp: Date()
        )
        #else
        // Intel Macs - GPU monitoring not supported (discrete GPU)
        // Return empty GPU data to indicate no GPU available
        gpuData = GPUData(timestamp: Date())
        #endif
    }

    /// Get physical memory size
    private func getPhysicalMemory() -> UInt64? {
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        guard sysctl(&mib, u_int(mib.count), &size, &len, nil, 0) == 0 else { return nil }
        return size
    }

    /// Thermal information structure
    private struct ThermalInfo {
        let cpuTemperature: Double?
        let gpuTemperature: Double?
        let fanSpeed: Int?
    }

    /// Get thermal information from SMC or IOPM
    private func getThermalInfo() -> ThermalInfo? {
        // Try IOPM thermal management
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IOPMThermalProfile"), &iterator) == KERN_SUCCESS else {
            return nil
        }

        defer { IOObjectRelease(iterator) }

        var cpuTemp: Double? = nil
        var gpuTemp: Double? = nil

        // Apple Silicon thermal zones
        let thermalZones = [
            "TC0E", // CPU
            "TC0F", // CPU
            "TC0c", // CPU
            "TG0E", // GPU (if available)
            "TG0P"  // GPU
        ]

        var service: io_object_t
        while (service = IOIteratorNext(iterator)), service != 0 {
            if let properties = IORegistryEntryCreateCFProperty(service, kIOPropertyThermalInformationKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                // Try to parse thermal info
                IOObjectRelease(service)
                // Thermal info parsing is complex - return nil for now
                // Temperature monitoring requires SMC access which is restricted
                break
            }
            IOObjectRelease(service)
        }

        return ThermalInfo(cpuTemperature: cpuTemp, gpuTemperature: gpuTemp, fanSpeed: nil)
    }

    // MARK: - Battery Monitoring

    private func updateBatteryData() {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFDictionary]

        guard let powerSources = sources else {
            batteryData = BatteryData(isPresent: false)
            return
        }

        for source in powerSources {
            let info = source as NSDictionary

            guard let type = info[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else {
                continue
            }

            let isPresent = info[kIOPSIsPresentKey] as? Bool ?? true
            guard isPresent else {
                batteryData = BatteryData(isPresent: false)
                return
            }

            let currentState = info[kIOPSPowerSourceStateKey] as? String
            let isCharging = currentState == kIOPSACPowerValue
            let isCharged = info[kIOPSIsChargedKey] as? Bool ?? false

            let capacity = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = info[kIOPSMaxCapacityKey] as? Int ?? 100

            let timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int

            // Battery health
            let designCapacity = info[kIOPSDesignCapacityKey] as? Int
            let health: BatteryHealth
            if let design = designCapacity, design > 0 {
                let healthPercent = Double(maxCapacity) / Double(design) * 100
                if healthPercent > 80 {
                    health = .good
                } else if healthPercent > 60 {
                    health = .fair
                } else {
                    health = .poor
                }
            } else {
                health = .unknown
            }

            batteryData = BatteryData(
                isPresent: true,
                isCharging: isCharging,
                isCharged: isCharged,
                chargePercentage: Double(capacity),
                estimatedMinutesRemaining: timeToEmpty,
                health: health
            )
            return
        }

        batteryData = BatteryData(isPresent: false)
    }

    // MARK: - Helper Methods

    private func addToHistory(_ array: inout [Double], value: Double, maxPoints: Int) {
        array.append(value)
        if array.count > maxPoints {
            array.removeFirst()
        }
    }

    /// Update top apps by CPU usage (call less frequently)
    public func updateTopCPUApps() {
        // This will be implemented in PerAppResourceMonitor (fn-2.4)
        topCPUApps = []
    }

    /// Update top apps by memory usage (call less frequently)
    public func updateTopMemoryApps() {
        // This will be implemented in PerAppResourceMonitor (fn-2.4)
        topMemoryApps = []
    }
}

// MARK: - C Types

private struct xsw_usage {
    var xsu_total: UInt64
    var xsu_used: UInt64
    var xsu_pagesize: UInt32
    var xsu_encrypted: UInt32
}
