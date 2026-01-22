//
//  SystemStatusDashboard.swift
//  Tonic
//
//  Real-time system status dashboard with CPU, memory, disk, network, battery, and uptime
//

import SwiftUI
import IOKit.ps

// MARK: - System Status Models

struct SystemStatus: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date

    // CPU
    let cpuUsage: Double // 0-100
    let activeProcesses: Int
    let totalThreads: Int

    // Memory
    let usedMemory: UInt64
    let totalMemory: UInt64
    let memoryPressure: MemoryPressure

    // Disk
    let diskUsage: [DiskVolume]

    // Network
    let networkBytesIn: UInt64
    let networkBytesOut: UInt64

    // Battery
    let batteryInfo: BatteryInfo?

    // Uptime
    let systemUptime: TimeInterval

    var memoryUsagePercentage: Double {
        guard totalMemory > 0 else { return 0 }
        return Double(usedMemory) / Double(totalMemory) * 100
    }

    static func == (lhs: SystemStatus, rhs: SystemStatus) -> Bool {
        lhs.timestamp == rhs.timestamp
    }
}

struct DiskVolume: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let usedBytes: UInt64
    let totalBytes: UInt64
    let isBootVolume: Bool

    var usagePercentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    var freeBytes: UInt64 {
        max(0, totalBytes - usedBytes)
    }
}

// MARK: - Battery Info

struct BatteryInfo: Equatable {
    let isPresent: Bool
    let isCharging: Bool
    let isCharged: Bool
    let chargePercentage: Double // 0-100
    let estimatedMinutesRemaining: Int?
    let batteryHealth: BatteryHealth

    var color: Color {
        if chargePercentage > 50 {
            return DesignTokens.Colors.progressLow
        } else if chargePercentage > 20 {
            return DesignTokens.Colors.progressMedium
        } else {
            return DesignTokens.Colors.progressHigh
        }
    }
}

// MARK: - System Monitor

@MainActor
class SystemMonitor: ObservableObject {
    @Published var currentStatus: SystemStatus?
    @Published var isMonitoring = false
    @Published var updateInterval: TimeInterval = 2.0

    private var timer: Timer?
    private var previousNetStats: NetworkStats?

    // CPU usage tracking
    private var previousCPUInfo: processor_info_array_t?
    private var previousNumCpuInfo: mach_msg_type_number_t = 0
    private var previousNumCPUs: UInt32 = 0
    private let cpuLock = NSLock()

    init() {
        startMonitoring()
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        updateStatus()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatus()
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        timer?.invalidate()
        timer = nil
    }

    func setUpdateInterval(_ interval: TimeInterval) {
        updateInterval = interval
        if isMonitoring {
            stopMonitoring()
            startMonitoring()
        }
    }

    private func updateStatus() {
        let cpuUsage = getCPUUsage()
        let (usedMem, totalMem) = getMemoryUsage()
        let pressure = getMemoryPressure()
        let volumes = getDiskUsage()
        let netIn = previousNetStats?.bytesIn ?? 0
        let netOut = previousNetStats?.bytesOut ?? 0
        let battery = getBatteryInfo()
        let uptime = getSystemUptime()
        let activeProcs = getActiveProcessCount()

        currentStatus = SystemStatus(
            timestamp: Date(),
            cpuUsage: cpuUsage,
            activeProcesses: activeProcs,
            totalThreads: getThreadCount(),
            usedMemory: usedMem,
            totalMemory: totalMem,
            memoryPressure: pressure,
            diskUsage: volumes,
            networkBytesIn: netIn,
            networkBytesOut: netOut,
            batteryInfo: battery,
            systemUptime: uptime
        )

        // Update network stats for next delta calculation
        previousNetStats = getNetworkStats()
    }

    // MARK: - CPU Monitoring

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

        if result != KERN_SUCCESS {
            return 0
        }

        cpuLock.lock()
        defer {
            cpuLock.unlock()
        }

        let inUse: Int
        if let info = cpuInfo {
            inUse = Int(info[Int(CPU_STATE_MAX)])
        } else {
            inUse = 0
        }
        let total = numTotalCpu

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
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: previousCPUInfo)), vm_size_t(Int(previousNumCpuInfo) * MemoryLayout<Int>.size))

        previousCPUInfo = cpuInfo
        previousNumCpuInfo = numCpuInfo
        previousNumCPUs = numTotalCpu

        return max(0, min(100, usage))
    }

    private func getActiveProcessCount() -> Int {
        var count: mach_msg_type_number_t = 0
        var result = task_info(
            mach_task_self_,
            UInt32(TASK_BASIC_INFO),
            nil,
            &count
        )

        var info = task_basic_info()
        result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(
                    mach_task_self_,
                    UInt32(TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }

        // Use proc list for actual process count
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var mibLen: Int = mib.count
        var size = MemoryLayout<kinfo_proc>.stride
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: 1024)

        sysctl(&mib, UInt32(mibLen), &procList, &size, nil, 0)

        return size / MemoryLayout<kinfo_proc>.stride
    }

    private func getThreadCount() -> Int {
        var count: mach_msg_type_number_t = 0
        var threads: thread_act_array_t?
        let result = task_threads(mach_task_self_, &threads, &count)

        if result == KERN_SUCCESS, let threads = threads {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.size))
        }

        return Int(count)
    }

    // MARK: - Memory Monitoring

    private func getMemoryUsage() -> (UInt64, UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (0, 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)

        // Used memory = active + wired
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count)) * pageSize
        let total = UInt64(stats.wire_count + stats.active_count + stats.inactive_count + stats.free_count) * pageSize

        // Get physical memory
        var memSize: Int = 0
        var memSizeLen = MemoryLayout<Int>.size
        sysctlbyname("hw.memsize", &memSize, &memSizeLen, nil, 0)

        return (used, UInt64(memSize))
    }

    private func getMemoryPressure() -> MemoryPressure {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return .normal
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let free = UInt64(stats.free_count) * pageSize
        let total = UInt64(stats.wire_count + stats.active_count + stats.inactive_count + stats.free_count) * pageSize

        let freePercentage = Double(free) / Double(total)

        if freePercentage < 0.05 {
            return .critical
        } else if freePercentage < 0.15 {
            return .warning
        }
        return .normal
    }

    // MARK: - Disk Monitoring

    private func getDiskUsage() -> [DiskVolume] {
        var volumes: [DiskVolume] = []

        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsRootFileSystemKey]

        if let volumesURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys) {
            let bootPath = FileManager.default.urls(for: .userDirectory, in: .localDomainMask).first?.deletingLastPathComponent().path ?? "/"

            for url in volumesURLs {
                guard let resourceValues = try? url.resourceValues(forKeys: Set(keys)),
                      let name = resourceValues.volumeName,
                      let total = resourceValues.volumeTotalCapacity,
                      let available = resourceValues.volumeAvailableCapacity else {
                    continue
                }

                let used = total - available
                let isBoot = resourceValues.volumeIsRootFileSystem ?? false

                volumes.append(DiskVolume(
                    name: name,
                    path: url.path,
                    usedBytes: UInt64(used),
                    totalBytes: UInt64(total),
                    isBootVolume: isBoot
                ))
            }
        }

        return volumes.sorted { $0.isBootVolume && !$1.isBootVolume }
    }

    // MARK: - Network Monitoring

    private struct NetworkStats {
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    private func getNetworkStats() -> NetworkStats {
        var totalBytesIn: UInt64 = 0
        var totalBytesOut: UInt64 = 0

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_IFLIST2]
        var mibLen = UInt32(mib.count)
        var len: Int = 0

        // Get buffer size needed
        sysctl(&mib, mibLen, nil, &len, nil, 0)

        var buffer = [Int8](repeating: 0, count: len)
        sysctl(&mib, mibLen, &buffer, &len, nil, 0)

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

    // MARK: - Battery Monitoring

    private func getBatteryInfo() -> BatteryInfo? {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFDictionary]

        guard let powerSources = sources else { return nil }

        for source in powerSources {
            let info = source as NSDictionary

            guard let type = info[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType else {
                continue
            }

            let isPresent = info[kIOPSIsPresentKey] as? Bool ?? true
            guard isPresent else { return nil }

            let currentState = info[kIOPSPowerSourceStateKey] as? String
            let isCharging = currentState == kIOPSACPowerValue
            let isCharged = info[kIOPSIsChargedKey] as? Bool ?? false

            let capacity = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = info[kIOPSMaxCapacityKey] as? Int ?? 100

            let timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int
            let estimatedMinutes = timeToEmpty ?? nil

            // Battery health estimation
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

            return BatteryInfo(
                isPresent: isPresent,
                isCharging: isCharging,
                isCharged: isCharged,
                chargePercentage: Double(capacity),
                estimatedMinutesRemaining: estimatedMinutes,
                batteryHealth: health
            )
        }

        return nil
    }

    // MARK: - Uptime

    private func getSystemUptime() -> TimeInterval {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size

        sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)

        var currentTime = timeval()
        gettimeofday(&currentTime, nil)

        let bootTimestamp = Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000.0
        let currentTimestamp = Double(currentTime.tv_sec) + Double(currentTime.tv_usec) / 1_000_000.0

        return currentTimestamp - bootTimestamp
    }
}

// MARK: - System Status Dashboard View

struct SystemStatusDashboard: View {
    @StateObject private var monitor = SystemMonitor()
    @State private var selectedUpdateInterval: TimeInterval = 2.0

    private let updateIntervals: [(value: TimeInterval, label: String)] = [
        (1.0, "1s"),
        (2.0, "2s"),
        (5.0, "5s"),
        (10.0, "10s")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            // Header
            HStack {
                SectionHeader(title: "System Status")

                Spacer()

                Picker("Update", selection: $selectedUpdateInterval) {
                    ForEach(updateIntervals, id: \.value) { interval in
                        Text(interval.label).tag(interval.value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: selectedUpdateInterval) { _, newValue in
                    monitor.setUpdateInterval(newValue)
                }
            }

            if let status = monitor.currentStatus {
                // Quick Stats Row
                HStack(spacing: DesignTokens.Spacing.md) {
                    CPUQuickStat(usage: status.cpuUsage)
                    MemoryQuickStat(usage: status.memoryUsagePercentage, pressure: status.memoryPressure)
                    UptimeQuickStat(uptime: status.systemUptime)
                }
                .padding(.bottom, DesignTokens.Spacing.sm)

                // Detailed Stats
                ScrollView {
                    VStack(spacing: DesignTokens.Spacing.lg) {
                        // CPU Section
                        CPUSection(status: status)

                        // Memory Section
                        MemorySection(status: status)

                        // Disk Section
                        DiskSection(volumes: status.diskUsage)

                        // Network Section
                        NetworkSection(bytesIn: status.networkBytesIn, bytesOut: status.networkBytesOut)

                        // Battery Section
                        if let battery = status.batteryInfo {
                            BatterySection(battery: battery)
                        }
                    }
                    .padding(.bottom, DesignTokens.Spacing.lg)
                }
            } else {
                LoadingState()
            }
        }
    }
}

// MARK: - Quick Stat Components

struct CPUQuickStat: View {
    let usage: Double

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Image(systemName: "cpu")
                    .foregroundColor(statusColor)
                Text("CPU")
                    .font(DesignTokens.Typography.captionLarge)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
            Text("\(Int(usage))%")
                .font(DesignTokens.Typography.displaySmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }

    private var statusColor: Color {
        switch usage {
        case 0..<50: return DesignTokens.Colors.progressLow
        case 50..<80: return DesignTokens.Colors.progressMedium
        default: return DesignTokens.Colors.progressHigh
        }
    }
}

struct MemoryQuickStat: View {
    let usage: Double
    let pressure: MemoryPressure

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Image(systemName: "memorychip")
                    .foregroundColor(pressure.color)
                Text("Memory")
                    .font(DesignTokens.Typography.captionLarge)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
            Text("\(Int(usage))%")
                .font(DesignTokens.Typography.displaySmall)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }
}

struct UptimeQuickStat: View {
    let uptime: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Image(systemName: "clock")
                    .foregroundColor(DesignTokens.Colors.accent)
                Text("Uptime")
                    .font(DesignTokens.Typography.captionLarge)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
            Text(formattedUptime)
                .font(DesignTokens.Typography.headlineMedium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }

    private var formattedUptime: String {
        let days = Int(uptime) / 86400
        let hours = Int(uptime) % 86400 / 3600
        let minutes = Int(uptime) % 3600 / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - Section Components

struct CPUSection: View {
    let status: SystemStatus

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SectionHeader(title: "CPU Usage")

                ProgressBar(value: status.cpuUsage, total: 100, color: cpuColor)

                HStack(spacing: DesignTokens.Spacing.xl) {
                    InfoRow(label: "Active Processes", value: "\(status.activeProcesses)")
                    InfoRow(label: "Threads", value: "\(status.totalThreads)")
                }
            }
        }
    }

    private var cpuColor: Color {
        switch status.cpuUsage {
        case 0..<50: return DesignTokens.Colors.progressLow
        case 50..<80: return DesignTokens.Colors.progressMedium
        default: return DesignTokens.Colors.progressHigh
        }
    }
}

struct MemorySection: View {
    let status: SystemStatus

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SectionHeader(title: "Memory")

                ProgressBar(value: status.memoryUsagePercentage, total: 100, color: status.memoryPressure.color)

                HStack(spacing: DesignTokens.Spacing.xl) {
                    InfoRow(label: "Used", value: formatBytes(status.usedMemory))
                    InfoRow(label: "Total", value: formatBytes(status.totalMemory))
                }

                HStack(spacing: DesignTokens.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(status.memoryPressure.color)
                    Text("Pressure: \(status.memoryPressure.rawValue)")
                        .font(DesignTokens.Typography.bodyMedium)
                        .foregroundColor(DesignTokens.Colors.textSecondary)
                }
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }
}

struct DiskSection: View {
    let volumes: [DiskVolume]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SectionHeader(title: "Disk Usage")

                ForEach(volumes) { volume in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Text(volume.name)
                                .font(DesignTokens.Typography.bodyMedium)
                                .fontWeight(.medium)

                            if volume.isBootVolume {
                                Badge(text: "Boot", color: DesignTokens.Colors.accent, size: .small)
                            }

                            Spacer()

                            Text("\(Int(volume.usagePercentage))%")
                                .font(DesignTokens.Typography.bodySmall)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }

                        ProgressBar(value: volume.usagePercentage, total: 100, height: 6)

                        HStack(spacing: DesignTokens.Spacing.md) {
                            InfoRow(label: "Free", value: formatBytes(volume.freeBytes))
                            InfoRow(label: "Total", value: formatBytes(volume.totalBytes))
                        }
                    }

                    if volume != volumes.last {
                        Divider()
                            .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                }
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1024 {
            return String(format: "%.1f TB", gb / 1024)
        }
        return String(format: "%.1f GB", gb)
    }
}

struct NetworkSection: View {
    let bytesIn: UInt64
    let bytesOut: UInt64

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SectionHeader(title: "Network Activity")

                HStack(spacing: DesignTokens.Spacing.xl) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(DesignTokens.Colors.progressLow)
                            Text("Download")
                                .font(DesignTokens.Typography.bodySmall)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                        Text(formatBytes(bytesIn))
                            .font(DesignTokens.Typography.headlineMedium)
                    }

                    Divider()
                        .frame(height: 40)

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(DesignTokens.Colors.progressMedium)
                            Text("Upload")
                                .font(DesignTokens.Typography.bodySmall)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                        Text(formatBytes(bytesOut))
                            .font(DesignTokens.Typography.headlineMedium)
                    }
                }
            }
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }
}

struct BatterySection: View {
    let battery: BatteryInfo

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SectionHeader(title: "Battery")

                HStack(spacing: DesignTokens.Spacing.md) {
                    // Battery icon
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(DesignTokens.Colors.border, lineWidth: 2)
                            .frame(width: 60, height: 28)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(battery.color)
                            .frame(width: CGFloat(battery.chargePercentage / 100) * 52, height: 20)
                            .padding(.leading, 4)

                        Rectangle()
                            .fill(DesignTokens.Colors.border)
                            .frame(width: 4, height: 12)
                            .offset(x: 30)
                    }

                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        Text("\(Int(battery.chargePercentage))%")
                            .font(DesignTokens.Typography.headlineMedium)

                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Image(systemName: battery.isCharging ? "bolt.fill" : "bolt.slash.fill")
                                .font(.caption)
                            Text(battery.isCharging ? "Charging" : "On Battery")
                                .font(DesignTokens.Typography.bodySmall)
                                .foregroundColor(DesignTokens.Colors.textSecondary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xxs) {
                        Text("Health: \(battery.batteryHealth.rawValue)")
                            .font(DesignTokens.Typography.captionMedium)
                            .foregroundColor(DesignTokens.Colors.textSecondary)

                        if let minutes = battery.estimatedMinutesRemaining {
                            Text("\(minutes / 60)h \(minutes % 60)m remaining")
                                .font(DesignTokens.Typography.captionMedium)
                                .foregroundColor(DesignTokens.Colors.textTertiary)
                        }
                    }
                }
            }
        }
    }
}

struct LoadingState: View {
    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            LoadingIndicator()
            Text("Loading system status...")
                .font(DesignTokens.Typography.bodySmall)
                .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xxl)
    }
}

// MARK: - Preview

#Preview {
    SystemStatusDashboard()
        .frame(width: 800, height: 600)
}
