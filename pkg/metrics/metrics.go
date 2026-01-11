package metrics

import (
	"context"
	"fmt"
	"os/exec"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/host"
	"github.com/shirou/gopsutil/v3/net"
)

type MetricsSnapshot struct {
	CollectedAt    time.Time
	Host           string
	Platform       string
	Uptime         string
	Procs          uint64
	Hardware       HardwareInfo
	HealthScore    int    // 0-100 system health score
	HealthScoreMsg string // Brief explanation

	CPU          CPUStatus
	GPU          []GPUStatus
	Memory       MemoryStatus
	Disks        []DiskStatus
	DiskIO       DiskIOStatus
	Network      []NetworkStatus
	Proxy        ProxyStatus
	Batteries    []BatteryStatus
	Thermal      ThermalStatus
	Sensors      []SensorReading
	Bluetooth    []BluetoothDevice
	TopProcesses []ProcessInfo
}

type HardwareInfo struct {
	Model       string // MacBook Pro 14-inch, 2021
	CPUModel    string // Apple M1 Pro / Intel Core i7
	TotalRAM    string // 16GB
	DiskSize    string // 512GB
	OSVersion   string // macOS Sonoma 14.5
	RefreshRate string // 120Hz / 60Hz
}

type DiskIOStatus struct {
	ReadRate  float64 // MB/s
	WriteRate float64 // MB/s
}

type ProcessInfo struct {
	Name   string
	CPU    float64
	Memory float64
}

type CPUStatus struct {
	Usage            float64
	PerCore          []float64
	PerCoreEstimated bool
	Load1            float64
	Load5            float64
	Load15           float64
	CoreCount        int
	LogicalCPU       int
	PCoreCount       int // Performance cores (Apple Silicon)
	ECoreCount       int // Efficiency cores (Apple Silicon)
}

type GPUStatus struct {
	Name        string
	Usage       float64
	MemoryUsed  float64
	MemoryTotal float64
	CoreCount   int
	Note        string
}

type MemoryStatus struct {
	Used        uint64
	Total       uint64
	UsedPercent float64
	SwapUsed    uint64
	SwapTotal   uint64
	Cached      uint64 // File cache that can be freed if needed
	Pressure    string // macOS memory pressure: normal/warn/critical
}

type DiskStatus struct {
	Mount       string
	Device      string
	Used        uint64
	Total       uint64
	UsedPercent float64
	Fstype      string
	External    bool
}

type NetworkStatus struct {
	Name      string
	RxRateMBs float64
	TxRateMBs float64
	IP        string
}

type ProxyStatus struct {
	Enabled bool
	Type    string // HTTP, SOCKS, System
	Host    string
}

type BatteryStatus struct {
	Percent    float64
	Status     string
	TimeLeft   string
	Health     string
	CycleCount int
	Capacity   int // Maximum capacity percentage (e.g., 85 means 85% of original)
}

type ThermalStatus struct {
	CPUTemp      float64
	GPUTemp      float64
	FanSpeed     int
	FanCount     int
	SystemPower  float64 // System power consumption in Watts
	AdapterPower float64 // AC adapter max power in Watts
	BatteryPower float64 // Battery charge/discharge power in Watts (positive = discharging)
}

type SensorReading struct {
	Label string
	Value float64
	Unit  string
	Note  string
}

type BluetoothDevice struct {
	Name      string
	Connected bool
	Battery   string
}

type Collector struct {
	// Static cache.
	cachedHW  HardwareInfo
	lastHWAt  time.Time
	hasStatic bool

	// Slow cache (30s-1m).
	lastBTAt time.Time
	lastBT   []BluetoothDevice

	// Fast metrics (1s).
	prevNet    map[string]net.IOCountersStat
	lastNetAt  time.Time
	lastGPUAt  time.Time
	cachedGPU  []GPUStatus
	prevDiskIO disk.IOCountersStat
	lastDiskAt time.Time
}

func NewCollector() *Collector {
	return &Collector{
		prevNet: make(map[string]net.IOCountersStat),
	}
}

func (c *Collector) Collect() (MetricsSnapshot, error) {
	now := time.Now()

	// Host info is cached by gopsutil; fetch once.
	hostInfo, _ := host.Info()

	var (
		wg       sync.WaitGroup
		errMu    sync.Mutex
		mergeErr error

		cpuStats     CPUStatus
		memStats     MemoryStatus
		diskStats    []DiskStatus
		diskIO       DiskIOStatus
		netStats     []NetworkStatus
		proxyStats   ProxyStatus
		batteryStats []BatteryStatus
		thermalStats ThermalStatus
		sensorStats  []SensorReading
		gpuStats     []GPUStatus
		btStats      []BluetoothDevice
		topProcs     []ProcessInfo
	)

	// Helper to launch concurrent collection.
	collect := func(fn func() error) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := fn(); err != nil {
				errMu.Lock()
				if mergeErr == nil {
					mergeErr = err
				} else {
					mergeErr = fmt.Errorf("%v; %w", mergeErr, err)
				}
				errMu.Unlock()
			}
		}()
	}

	// Launch independent collection tasks.
	collect(func() (err error) { cpuStats, err = collectCPU(); return })
	collect(func() (err error) { memStats, err = collectMemory(); return })
	collect(func() (err error) { diskStats, err = collectDisks(); return })
	collect(func() (err error) { diskIO = c.collectDiskIO(now); return nil })
	collect(func() (err error) { netStats, err = c.collectNetwork(now); return })
	collect(func() (err error) { proxyStats = collectProxy(); return nil })
	collect(func() (err error) { batteryStats, _ = collectBatteries(); return nil })
	collect(func() (err error) { thermalStats = collectThermal(); return nil })
	collect(func() (err error) { sensorStats, _ = collectSensors(); return nil })
	collect(func() (err error) { gpuStats, err = c.collectGPU(now); return })
	collect(func() (err error) {
		// Bluetooth is slow; cache for 30s.
		if now.Sub(c.lastBTAt) > 30*time.Second || len(c.lastBT) == 0 {
			btStats = c.collectBluetooth(now)
			c.lastBT = btStats
			c.lastBTAt = now
		} else {
			btStats = c.lastBT
		}
		return nil
	})
	collect(func() (err error) { topProcs = collectTopProcesses(); return nil })

	// Wait for all to complete.
	wg.Wait()

	// Dependent tasks (post-collect).
	// Cache hardware info as it's expensive and rarely changes.
	if !c.hasStatic || now.Sub(c.lastHWAt) > 10*time.Minute {
		c.cachedHW = collectHardware(memStats.Total, diskStats)
		c.lastHWAt = now
		c.hasStatic = true
	}
	hwInfo := c.cachedHW

	score, scoreMsg := calculateHealthScore(cpuStats, memStats, diskStats, diskIO, thermalStats)

	return MetricsSnapshot{
		CollectedAt:    now,
		Host:           hostInfo.Hostname,
		Platform:       fmt.Sprintf("%s %s", hostInfo.Platform, hostInfo.PlatformVersion),
		Uptime:         formatUptime(hostInfo.Uptime),
		Procs:          hostInfo.Procs,
		Hardware:       hwInfo,
		HealthScore:    score,
		HealthScoreMsg: scoreMsg,
		CPU:            cpuStats,
		GPU:            gpuStats,
		Memory:         memStats,
		Disks:          diskStats,
		DiskIO:         diskIO,
		Network:        netStats,
		Proxy:          proxyStats,
		Batteries:      batteryStats,
		Thermal:        thermalStats,
		Sensors:        sensorStats,
		Bluetooth:      btStats,
		TopProcesses:   topProcs,
	}, mergeErr
}

func runCmd(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

func commandExists(name string) bool {
	if name == "" {
		return false
	}
	defer func() {
		// Treat LookPath panics as "missing".
		_ = recover()
	}()
	_, err := exec.LookPath(name)
	return err == nil
}
