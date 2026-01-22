# fn-2.2 Build widget data manager service

## Description

Create the central data manager that aggregates system monitoring data and distributes it to widgets. This service coordinates all monitoring operations.

**Files to create:**
- `Tonic/Services/WidgetDataManager.swift` - Main data manager

**Responsibilities:**
- Aggregate data from SystemMonitor (existing)
- Provide @Observable properties for widget data
- Manage update timers for different widget types
- Cache history data for graphs (60 points)

**Key properties:**
```swift
@Observable
final class WidgetDataManager {
    static let shared = WidgetDataManager()

    // CPU data
    var cpuUsage: Double
    var cpuHistory: [Double]
    var perCoreCPU: [Double]
    var topCPUApps: [(name: String, usage: Double)]

    // Memory data
    var memoryUsage: Double
    var memoryPressure: MemoryPressure
    var swapUsed: Int64

    // Disk data
    var diskUsage: [DiskVolume]
    var diskActivity: Bool

    // Network data
    var networkUp: Int64
    var networkDown: Int64
    var isConnected: Bool

    // GPU data (optional)
    var gpuUsage: Double?

    func startMonitoring()
    func stopMonitoring()
}
```

**Reuse:** `Tonic/Views/SystemStatusDashboard.swift:111-505` SystemMonitor class

**Update intervals:**
- CPU/GPU/Memory: 2 seconds
- Disk/Network: 5 seconds

## Acceptance

- [ ] WidgetDataManager class with @Observable
- [ ] Singleton pattern with static shared
- [ ] Properties for all widget data types
- [ ] History arrays (60 points) for graphs
- [ ] startMonitoring() sets up DispatchSourceTimer
- [ ] Data updates from existing SystemMonitor
- [ ] GPU data gracefully nil when unavailable

## Done summary
Created WidgetDataManager service that aggregates system data from SystemMonitor. Provides @Observable properties for all widget types with history tracking (60 points) for graphs. Includes CPUData, MemoryData, DiskVolumeData, NetworkData, GPUData, BatteryData, and AppResourceUsage models. Uses DispatchSourceTimer for efficient polling with configurable intervals. GPU data gracefully nil when unavailable. Reuses existing SystemMonitor patterns for CPU, memory, disk, network, and battery monitoring.
## Evidence
- Commits:
- Tests:
- PRs: