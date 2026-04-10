package main

import (
	"context"
	"fmt"
	"os/exec"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/net"
)

// RingBuffer is a fixed-size circular buffer for float64 values.
type RingBuffer struct {
	data  []float64
	index int // Current insert position (oldest value)
	size  int // Number of valid elements
	cap   int // Total capacity
}

func NewRingBuffer(capacity int) *RingBuffer {
	return &RingBuffer{
		data: make([]float64, capacity),
		cap:  capacity,
	}
}

func (rb *RingBuffer) Add(val float64) {
	rb.data[rb.index] = val
	rb.index = (rb.index + 1) % rb.cap
	if rb.size < rb.cap {
		rb.size++
	}
}

// Slice returns the data in chronological order (oldest to newest).
func (rb *RingBuffer) Slice() []float64 {
	if rb.size == 0 {
		return nil
	}
	res := make([]float64, rb.size)
	if rb.size < rb.cap {
		// Not full yet: data is at [0 : size]
		copy(res, rb.data[:rb.size])
	} else {
		// Full: oldest is at index, then wrapped
		// data: [4, 5, 1, 2, 3] (cap=5, index=2, oldest=1)
		// want: [1, 2, 3, 4, 5]
		// part1: [index:] -> [1, 2, 3]
		// part2: [:index] -> [4, 5]
		copy(res, rb.data[rb.index:])
		copy(res[rb.cap-rb.index:], rb.data[:rb.index])
	}
	return res
}

type MetricsSnapshot struct {
	CollectedAt    time.Time    `json:"collected_at"`
	Host           string       `json:"host"`
	Platform       string       `json:"platform"`
	Uptime         string       `json:"uptime"`
	UptimeSeconds  uint64       `json:"uptime_seconds"`
	Procs          uint64       `json:"procs"`
	Hardware       HardwareInfo `json:"hardware"`
	HealthScore    int          `json:"health_score"`     // 0-100 system health score
	HealthScoreMsg string       `json:"health_score_msg"` // Brief explanation

	CPU            CPUStatus          `json:"cpu"`
	GPU            []GPUStatus        `json:"gpu"`
	Memory         MemoryStatus       `json:"memory"`
	Disks          []DiskStatus       `json:"disks"`
	TrashSize      uint64             `json:"trash_size"`
	TrashApprox    bool               `json:"trash_approx"`
	DiskIO         DiskIOStatus       `json:"disk_io"`
	Network        []NetworkStatus    `json:"network"`
	NetworkHistory NetworkHistory     `json:"network_history"`
	Proxy          ProxyStatus        `json:"proxy"`
	Batteries      []BatteryStatus    `json:"batteries"`
	Thermal        ThermalStatus      `json:"thermal"`
	Sensors        []SensorReading    `json:"sensors"`
	Bluetooth      []BluetoothDevice  `json:"bluetooth"`
	TopProcesses   []ProcessInfo      `json:"top_processes"`
	ProcessWatch   ProcessWatchConfig `json:"process_watch"`
	ProcessAlerts  []ProcessAlert     `json:"process_alerts"`
}

type HardwareInfo struct {
	Model       string `json:"model"`        // MacBook Pro 14-inch, 2021
	CPUModel    string `json:"cpu_model"`    // Apple M1 Pro / Intel Core i7
	TotalRAM    string `json:"total_ram"`    // 16GB
	DiskSize    string `json:"disk_size"`    // 512GB
	OSVersion   string `json:"os_version"`   // macOS Sonoma 14.5
	RefreshRate string `json:"refresh_rate"` // 120Hz / 60Hz
}

type DiskIOStatus struct {
	ReadRate  float64 `json:"read_rate"`  // MB/s
	WriteRate float64 `json:"write_rate"` // MB/s
}

type ProcessInfo struct {
	PID     int     `json:"pid"`
	PPID    int     `json:"ppid"`
	Name    string  `json:"name"`
	Command string  `json:"command"`
	CPU     float64 `json:"cpu"`
	Memory  float64 `json:"memory"`
}

type CPUStatus struct {
	Usage            float64   `json:"usage"`
	PerCore          []float64 `json:"per_core"`
	PerCoreEstimated bool      `json:"per_core_estimated"`
	Load1            float64   `json:"load1"`
	Load5            float64   `json:"load5"`
	Load15           float64   `json:"load15"`
	CoreCount        int       `json:"core_count"`
	LogicalCPU       int       `json:"logical_cpu"`
	PCoreCount       int       `json:"p_core_count"` // Performance cores (Apple Silicon)
	ECoreCount       int       `json:"e_core_count"` // Efficiency cores (Apple Silicon)
}

type GPUStatus struct {
	Name        string  `json:"name"`
	Usage       float64 `json:"usage"`
	MemoryUsed  float64 `json:"memory_used"`
	MemoryTotal float64 `json:"memory_total"`
	CoreCount   int     `json:"core_count"`
	Note        string  `json:"note"`
}

type MemoryStatus struct {
	Used        uint64  `json:"used"`
	Total       uint64  `json:"total"`
	UsedPercent float64 `json:"used_percent"`
	SwapUsed    uint64  `json:"swap_used"`
	SwapTotal   uint64  `json:"swap_total"`
	Cached      uint64  `json:"cached"`   // File cache that can be freed if needed
	Pressure    string  `json:"pressure"` // macOS memory pressure: normal/warn/critical
}

type DiskStatus struct {
	Mount       string  `json:"mount"`
	Device      string  `json:"device"`
	Used        uint64  `json:"used"`
	Total       uint64  `json:"total"`
	UsedPercent float64 `json:"used_percent"`
	Fstype      string  `json:"fstype"`
	External    bool    `json:"external"`
}

type NetworkStatus struct {
	Name      string  `json:"name"`
	RxRateMBs float64 `json:"rx_rate_mbs"`
	TxRateMBs float64 `json:"tx_rate_mbs"`
	IP        string  `json:"ip"`
}

// NetworkHistory holds the global network usage history.
type NetworkHistory struct {
	RxHistory []float64 `json:"rx_history"`
	TxHistory []float64 `json:"tx_history"`
}

const NetworkHistorySize = 120 // Increased history size for wider graph

type ProxyStatus struct {
	Enabled bool   `json:"enabled"`
	Type    string `json:"type"` // HTTP, HTTPS, SOCKS, PAC, WPAD, TUN
	Host    string `json:"host"`
}

type BatteryStatus struct {
	Percent    float64 `json:"percent"`
	Status     string  `json:"status"`
	TimeLeft   string  `json:"time_left"`
	Health     string  `json:"health"`
	CycleCount int     `json:"cycle_count"`
	Capacity   int     `json:"capacity"` // Maximum capacity percentage (e.g., 85 means 85% of original)
}

type ThermalStatus struct {
	CPUTemp      float64 `json:"cpu_temp"`
	GPUTemp      float64 `json:"gpu_temp"`
	BatteryTemp  float64 `json:"battery_temp"` // Battery temperature in Celsius when exposed by AppleSmartBattery
	FanSpeed     int     `json:"fan_speed"`
	FanCount     int     `json:"fan_count"`
	SystemPower  float64 `json:"system_power"`  // System power consumption in Watts
	AdapterPower float64 `json:"adapter_power"` // AC adapter max power in Watts
	BatteryPower float64 `json:"battery_power"` // Battery charge/discharge power in Watts (positive = discharging)
}

type SensorReading struct {
	Label string  `json:"label"`
	Value float64 `json:"value"`
	Unit  string  `json:"unit"`
	Note  string  `json:"note"`
}

type BluetoothDevice struct {
	Name      string `json:"name"`
	Connected bool   `json:"connected"`
	Battery   string `json:"battery"`
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
	prevNet      map[string]net.IOCountersStat
	lastNetAt    time.Time
	rxHistoryBuf *RingBuffer
	txHistoryBuf *RingBuffer
	lastGPUAt    time.Time
	cachedGPU    []GPUStatus
	prevDiskIO   disk.IOCountersStat
	lastDiskAt   time.Time

	watchMu        sync.Mutex
	processWatch   ProcessWatchConfig
	processWatcher *ProcessWatcher
}

func NewCollector(options ProcessWatchOptions) *Collector {
	return &Collector{
		prevNet:        make(map[string]net.IOCountersStat),
		rxHistoryBuf:   NewRingBuffer(NetworkHistorySize),
		txHistoryBuf:   NewRingBuffer(NetworkHistorySize),
		processWatch:   options.SnapshotConfig(),
		processWatcher: NewProcessWatcher(options),
	}
}

func (c *Collector) Collect() (MetricsSnapshot, error) {
	now := time.Now()

	// Host info is cached by gopsutil; fetch once.
	hostInfo, _ := host.Info()
	if hostInfo == nil {
		hostInfo = &host.InfoStat{}
	}

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
		allProcs     []ProcessInfo
	)

	// Helper to launch concurrent collection.
	collect := func(fn func() error) {
		wg.Go(func() {
			defer func() {
				if r := recover(); r != nil {
					errMu.Lock()
					panicErr := fmt.Errorf("collector panic: %v", r)
					if mergeErr == nil {
						mergeErr = panicErr
					} else {
						mergeErr = fmt.Errorf("%v; %w", mergeErr, panicErr)
					}
					errMu.Unlock()
				}
			}()
			if err := fn(); err != nil {
				errMu.Lock()
				if mergeErr == nil {
					mergeErr = err
				} else {
					mergeErr = fmt.Errorf("%v; %w", mergeErr, err)
				}
				errMu.Unlock()
			}
		})
	}

	// Launch independent collection tasks.
	collect(func() (err error) { cpuStats, err = collectCPU(); return })
	collect(func() (err error) { memStats, err = collectMemory(); return })
	collect(func() (err error) { diskStats, err = collectDisks(); return })
	var trashSize uint64
	var trashApprox bool
	collect(func() (err error) { trashSize, trashApprox = collectTrashSize(); return nil })
	collect(func() (err error) { diskIO = c.collectDiskIO(now); return nil })
	collect(func() (err error) { netStats, err = c.collectNetwork(now); return })
	collect(func() (err error) { proxyStats = collectProxy(); return nil })
	collect(func() (err error) { batteryStats, _ = collectBatteries(); return nil })
	collect(func() (err error) { thermalStats = collectThermal(); return nil })
	// Sensors disabled - CPU temp already shown in CPU card
	// collect(func() (err error) { sensorStats, _ = collectSensors(); return nil })
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
	collect(func() (err error) { allProcs, err = collectProcesses(); return })

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

	score, scoreMsg := calculateHealthScore(cpuStats, memStats, diskStats, diskIO, thermalStats, batteryStats, hostInfo.Uptime)
	topProcs := topProcesses(allProcs, 5)

	var processAlerts []ProcessAlert
	c.watchMu.Lock()
	if c.processWatcher != nil {
		processAlerts = c.processWatcher.Update(now, allProcs)
	}
	c.watchMu.Unlock()

	return MetricsSnapshot{
		CollectedAt:    now,
		Host:           hostInfo.Hostname,
		Platform:       fmt.Sprintf("%s %s", hostInfo.Platform, hostInfo.PlatformVersion),
		Uptime:         formatUptime(hostInfo.Uptime),
		UptimeSeconds:  hostInfo.Uptime,
		Procs:          hostInfo.Procs,
		Hardware:       hwInfo,
		HealthScore:    score,
		HealthScoreMsg: scoreMsg,
		CPU:            cpuStats,
		GPU:            gpuStats,
		Memory:         memStats,
		Disks:          diskStats,
		TrashSize:      trashSize,
		TrashApprox:    trashApprox,
		DiskIO:         diskIO,
		Network:        netStats,
		NetworkHistory: NetworkHistory{
			RxHistory: c.rxHistoryBuf.Slice(),
			TxHistory: c.txHistoryBuf.Slice(),
		},
		Proxy:         proxyStats,
		Batteries:     batteryStats,
		Thermal:       thermalStats,
		Sensors:       sensorStats,
		Bluetooth:     btStats,
		TopProcesses:  topProcs,
		ProcessWatch:  c.processWatch,
		ProcessAlerts: processAlerts,
	}, mergeErr
}

var runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

var commandExists = func(name string) bool {
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
