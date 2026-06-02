package main

import (
	"context"
	"fmt"
	"os/exec"
	"slices"
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
	PID         int     `json:"pid"`
	PPID        int     `json:"ppid"`
	Name        string  `json:"name"`
	Command     string  `json:"command"`
	CPU         float64 `json:"cpu"`
	Memory      float64 `json:"memory"` // Percent of physical memory, kept for compatibility.
	MemoryBytes uint64  `json:"memory_bytes,omitempty"`
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
	Available   uint64  `json:"available"`
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
	prevNet        map[string]net.IOCountersStat
	lastNetAt      time.Time
	rxHistoryBuf   *RingBuffer
	txHistoryBuf   *RingBuffer
	lastNetIPAt    time.Time
	cachedNetIPs   map[string]string
	lastGPUAt      time.Time
	cachedGPU      []GPUStatus
	lastGPUUsageAt time.Time
	cachedGPUUsage float64
	prevDiskIO     disk.IOCountersStat
	lastDiskAt     time.Time

	watchMu        sync.Mutex
	processWatch   ProcessWatchConfig
	processWatcher *ProcessWatcher
	enrichment     snapshotEnrichment
	hasEnrichment  bool
}

type collectedMetrics struct {
	cpuStats     CPUStatus
	memStats     MemoryStatus
	diskStats    []DiskStatus
	trashSize    uint64
	trashApprox  bool
	diskIO       DiskIOStatus
	netStats     []NetworkStatus
	proxyStats   ProxyStatus
	batteryStats []BatteryStatus
	thermalStats ThermalStatus
	sensorStats  []SensorReading
	gpuStats     []GPUStatus
	btStats      []BluetoothDevice
	allProcs     []ProcessInfo
	hasProcesses bool
}

type snapshotEnrichment struct {
	// When adding MetricsSnapshot fields, update
	// TestMetricsSnapshotFieldsHaveCollectionClassifications.
	hardware       HardwareInfo
	cpuPCores      int
	cpuECores      int
	memoryCached   uint64
	memoryPressure string
	disks          []DiskStatus
	hasDisks       bool
	gpu            []GPUStatus
	trashSize      uint64
	trashApprox    bool
	proxy          ProxyStatus
	batteries      []BatteryStatus
	thermal        ThermalStatus
	sensors        []SensorReading
	bluetooth      []BluetoothDevice
	topProcesses   []ProcessInfo
	processAlerts  []ProcessAlert
}

func NewCollector(options ProcessWatchOptions) *Collector {
	c := &Collector{
		prevNet:        make(map[string]net.IOCountersStat),
		rxHistoryBuf:   NewRingBuffer(NetworkHistorySize),
		txHistoryBuf:   NewRingBuffer(NetworkHistorySize),
		cachedNetIPs:   make(map[string]string),
		processWatch:   options.SnapshotConfig(),
		processWatcher: NewProcessWatcher(options),
	}
	c.primeNetworkCounters(time.Now())
	return c
}

func collectHostInfo() *host.InfoStat {
	hostInfo, _ := host.Info()
	if hostInfo == nil {
		hostInfo = &host.InfoStat{}
	}
	return hostInfo
}

func collectConcurrently(tasks ...func() error) error {
	var (
		wg     sync.WaitGroup
		errMu  sync.Mutex
		merged error
	)

	for _, task := range tasks {
		wg.Go(func() {
			defer func() {
				if r := recover(); r != nil {
					errMu.Lock()
					panicErr := fmt.Errorf("collector panic: %v", r)
					if merged == nil {
						merged = panicErr
					} else {
						merged = fmt.Errorf("%v; %w", merged, panicErr)
					}
					errMu.Unlock()
				}
			}()
			if err := task(); err != nil {
				errMu.Lock()
				if merged == nil {
					merged = err
				} else {
					merged = fmt.Errorf("%v; %w", merged, err)
				}
				errMu.Unlock()
			}
		})
	}

	wg.Wait()
	return merged
}

func (c *Collector) CollectFast() (MetricsSnapshot, error) {
	return c.collectFast(false)
}

func (c *Collector) CollectProcesses() (MetricsSnapshot, error) {
	return c.collectFast(true)
}

func (c *Collector) collectFast(includeProcesses bool) (MetricsSnapshot, error) {
	now := time.Now()
	hostInfo := collectHostInfo()
	var collected collectedMetrics

	tasks := []func() error{
		func() (err error) { collected.cpuStats, err = collectCPUFast(); return },
		func() (err error) { collected.memStats, err = collectMemoryFast(); return },
		func() (err error) { collected.diskStats, err = collectDisksFast(); return },
		func() (err error) { collected.diskIO = c.collectDiskIO(now); return nil },
		func() (err error) { collected.netStats = c.collectNetwork(now); return nil },
	}
	if includeProcesses {
		tasks = append(tasks, func() error { return collectProcessesInto(&collected) })
	}

	mergeErr := collectConcurrently(tasks...)

	snapshot := c.snapshotFromMetrics(now, hostInfo, collected, false)
	c.applyEnrichment(&snapshot, collected.hasProcesses)
	return snapshot, mergeErr
}

func (c *Collector) Collect() (MetricsSnapshot, error) {
	return c.collectFull()
}

func (c *Collector) collectFull() (MetricsSnapshot, error) {
	now := time.Now()
	hostInfo := collectHostInfo()
	var collected collectedMetrics

	// Launch independent collection tasks.
	tasks := []func() error{
		func() (err error) { collected.cpuStats, err = collectCPU(); return },
		func() (err error) { collected.memStats, err = collectMemory(); return },
		func() (err error) { collected.diskStats, err = collectDisks(); return },
		func() (err error) { collected.trashSize, collected.trashApprox = collectTrashSize(); return nil },
		func() (err error) { collected.diskIO = c.collectDiskIO(now); return nil },
		func() (err error) { collected.netStats = c.collectNetwork(now); return nil },
		func() (err error) { collected.proxyStats = collectProxy(); return nil },
		func() (err error) { collected.batteryStats, _ = collectBatteries(); return nil },
		func() (err error) { collected.thermalStats = collectThermal(); return nil },
		// Sensors disabled - CPU temp already shown in CPU card
		// collect(func() (err error) { sensorStats, _ = collectSensors(); return nil })
		func() (err error) { collected.gpuStats, err = c.collectGPU(now); return },
		func() (err error) {
			// Bluetooth is slow; cache for 30s.
			if now.Sub(c.lastBTAt) > 30*time.Second || len(c.lastBT) == 0 {
				collected.btStats = c.collectBluetooth(now)
				c.lastBT = collected.btStats
				c.lastBTAt = now
			} else {
				collected.btStats = c.lastBT
			}
			return nil
		},
		func() error { return collectProcessesInto(&collected) },
	}
	mergeErr := collectConcurrently(tasks...)

	snapshot := c.snapshotFromMetrics(now, hostInfo, collected, true)
	if mergeErr == nil {
		c.cacheEnrichment(snapshot)
	}
	return snapshot, mergeErr
}

func collectProcessesInto(collected *collectedMetrics) error {
	procs, err := collectProcessesFunc()
	if err != nil {
		return err
	}
	collected.allProcs = procs
	collected.hasProcesses = true
	return nil
}

func (c *Collector) snapshotFromMetrics(now time.Time, hostInfo *host.InfoStat, collected collectedMetrics, refreshHardware bool) MetricsSnapshot {
	// Dependent tasks (post-collect).
	// Cache hardware info as it's expensive and rarely changes.
	if refreshHardware && (!c.hasStatic || now.Sub(c.lastHWAt) > 10*time.Minute) {
		c.cachedHW = collectHardware(collected.memStats.Total, collected.diskStats)
		c.lastHWAt = now
		c.hasStatic = true
	}
	hwInfo := c.hardwareForSnapshot()

	score, scoreMsg := calculateHealthScore(
		collected.cpuStats,
		collected.memStats,
		collected.diskStats,
		collected.diskIO,
		collected.thermalStats,
		collected.batteryStats,
		hostInfo.Uptime,
	)
	var topProcs []ProcessInfo
	if collected.hasProcesses {
		topProcs = topProcesses(collected.allProcs, 5)
	}

	var processAlerts []ProcessAlert
	c.watchMu.Lock()
	if c.processWatcher != nil {
		if collected.hasProcesses {
			processAlerts = c.processWatcher.Update(now, collected.allProcs)
		} else {
			processAlerts = c.processWatcher.Snapshot()
		}
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
		CPU:            collected.cpuStats,
		GPU:            collected.gpuStats,
		Memory:         collected.memStats,
		Disks:          collected.diskStats,
		TrashSize:      collected.trashSize,
		TrashApprox:    collected.trashApprox,
		DiskIO:         collected.diskIO,
		Network:        collected.netStats,
		NetworkHistory: NetworkHistory{
			RxHistory: c.rxHistoryBuf.Slice(),
			TxHistory: c.txHistoryBuf.Slice(),
		},
		Proxy:         collected.proxyStats,
		Batteries:     collected.batteryStats,
		Thermal:       collected.thermalStats,
		Sensors:       collected.sensorStats,
		Bluetooth:     collected.btStats,
		TopProcesses:  topProcs,
		ProcessWatch:  c.processWatch,
		ProcessAlerts: processAlerts,
	}
}

func (c *Collector) hardwareForSnapshot() HardwareInfo {
	if c.hasStatic {
		return c.cachedHW
	}
	return HardwareInfo{}
}

func (c *Collector) cacheEnrichment(snapshot MetricsSnapshot) {
	c.enrichment = snapshotEnrichment{
		hardware:       snapshot.Hardware,
		cpuPCores:      snapshot.CPU.PCoreCount,
		cpuECores:      snapshot.CPU.ECoreCount,
		memoryCached:   snapshot.Memory.Cached,
		memoryPressure: snapshot.Memory.Pressure,
		disks:          slices.Clone(snapshot.Disks),
		hasDisks:       true,
		gpu:            slices.Clone(snapshot.GPU),
		trashSize:      snapshot.TrashSize,
		trashApprox:    snapshot.TrashApprox,
		proxy:          snapshot.Proxy,
		batteries:      slices.Clone(snapshot.Batteries),
		thermal:        snapshot.Thermal,
		sensors:        slices.Clone(snapshot.Sensors),
		bluetooth:      slices.Clone(snapshot.Bluetooth),
		topProcesses:   slices.Clone(snapshot.TopProcesses),
		processAlerts:  slices.Clone(snapshot.ProcessAlerts),
	}
	c.hasEnrichment = true
}

func (c *Collector) applyEnrichment(snapshot *MetricsSnapshot, preserveLiveProcesses bool) {
	if snapshot == nil || !c.hasEnrichment {
		return
	}
	c.enrichment.apply(snapshot, preserveLiveProcesses)
	snapshot.HealthScore, snapshot.HealthScoreMsg = calculateHealthScore(
		snapshot.CPU,
		snapshot.Memory,
		snapshot.Disks,
		snapshot.DiskIO,
		snapshot.Thermal,
		snapshot.Batteries,
		snapshot.UptimeSeconds,
	)
}

func (e snapshotEnrichment) apply(snapshot *MetricsSnapshot, preserveLiveProcesses bool) {
	snapshot.Hardware = e.hardware
	snapshot.CPU.PCoreCount = e.cpuPCores
	snapshot.CPU.ECoreCount = e.cpuECores
	snapshot.Memory.Cached = e.memoryCached
	snapshot.Memory.Pressure = e.memoryPressure
	// Disk capacity is slow-changing and the corrections (APFS purgeable,
	// diskutil, Finder) are expensive, so the fast path collects raw statfs
	// values and we overwrite them with the last full-refresh corrected
	// snapshot. DiskIO stays live. Skip when the cache is empty so the first
	// fast paint still shows raw disks instead of a blank card.
	if e.hasDisks && len(e.disks) > 0 {
		snapshot.Disks = slices.Clone(e.disks)
	}
	snapshot.GPU = slices.Clone(e.gpu)
	snapshot.TrashSize = e.trashSize
	snapshot.TrashApprox = e.trashApprox
	snapshot.Proxy = e.proxy
	snapshot.Batteries = slices.Clone(e.batteries)
	snapshot.Thermal = e.thermal
	snapshot.Sensors = slices.Clone(e.sensors)
	snapshot.Bluetooth = slices.Clone(e.bluetooth)
	if !preserveLiveProcesses {
		snapshot.TopProcesses = slices.Clone(e.topProcesses)
		snapshot.ProcessAlerts = slices.Clone(e.processAlerts)
	}
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

	commandExistsCacheMu.Lock()
	if exists, ok := commandExistsCache[name]; ok {
		commandExistsCacheMu.Unlock()
		return exists
	}
	commandExistsCacheMu.Unlock()

	exists := lookPathExists(name)

	commandExistsCacheMu.Lock()
	commandExistsCache[name] = exists
	commandExistsCacheMu.Unlock()
	return exists
}

var (
	commandExistsCacheMu sync.Mutex
	commandExistsCache   = make(map[string]bool)
)

func lookPathExists(name string) (exists bool) {
	defer func() {
		if recover() != nil {
			exists = false
		}
	}()
	_, err := exec.LookPath(name)
	return err == nil
}
