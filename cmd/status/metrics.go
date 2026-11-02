package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
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
	// RestartReason names why a restart is advisable (pending kernel update);
	// empty when none. Uptime alone never sets it.
	RestartReason string `json:"restart_reason,omitempty"`

	CPU                   CPUStatus           `json:"cpu"`
	GPU                   []GPUStatus         `json:"gpu"`
	Memory                MemoryStatus        `json:"memory"`
	Disks                 []DiskStatus        `json:"disks"`
	TrashSize             uint64              `json:"trash_size"`
	TrashApprox           bool                `json:"trash_approx"`
	DiskIO                DiskIOStatus        `json:"disk_io"`
	Network               []NetworkStatus     `json:"network"`
	NetworkHistory        NetworkHistory      `json:"network_history"`
	Proxy                 ProxyStatus         `json:"proxy"`
	Batteries             []BatteryStatus     `json:"batteries"`
	Peripherals           []PeripheralBattery `json:"peripherals"`
	Thermal               ThermalStatus       `json:"thermal"`
	Sensors               []SensorReading     `json:"sensors"`
	TopProcesses          []ProcessInfo       `json:"top_processes"`
	TopApps               []AppInfo           `json:"top_apps"`
	ProcessCollectedAt    *time.Time          `json:"process_collected_at,omitempty"`
	ProcessStale          *bool               `json:"process_stale,omitempty"`
	ZombieCount           *int                `json:"zombie_count,omitempty"`
	ZombieParents         []ZombieParent      `json:"zombie_parents"`
	ZombieParentsComplete *bool               `json:"zombie_parents_complete,omitempty"`
	ProcessWatch          ProcessWatchConfig  `json:"process_watch"`
	ProcessAlerts         []ProcessAlert      `json:"process_alerts"`
}

type HardwareInfo struct {
	Model     string `json:"model"`      // LENOVO 20XW ThinkPad X1 Carbon Gen 9; empty when DMI has nothing real
	CPUModel  string `json:"cpu_model"`  // 11th Gen Intel(R) Core(TM) i7-1185G7
	TotalRAM  string `json:"total_ram"`  // 16GB
	DiskSize  string `json:"disk_size"`  // Root filesystem, 512GB
	OSVersion string `json:"os_version"` // Arch Linux, kernel 6.12.1-arch1-1
}

type DiskIOStatus struct {
	ReadRate  float64 `json:"read_rate"`  // MB/s
	WriteRate float64 `json:"write_rate"` // MB/s
}

type ProcessInfo struct {
	PID         int     `json:"pid"`
	PPID        int     `json:"ppid"`
	State       string  `json:"-"`
	Name        string  `json:"name"`
	Command     string  `json:"command"`
	CPU         float64 `json:"cpu"`
	Memory      float64 `json:"memory"` // Percent of physical memory, kept for compatibility.
	MemoryBytes uint64  `json:"memory_bytes,omitempty"`
	// GPUMemoryBytes is DRM fdinfo memory, filled only for the processes
	// behind the rows on screen on machines with a GPU; 0 means not measured.
	GPUMemoryBytes uint64 `json:"gpu_memory_bytes,omitempty"`
	// AppID is the application id from the process's systemd app cgroup.
	AppID string `json:"-"`
}

type ZombieParent struct {
	PID   int    `json:"pid"`
	Name  string `json:"name"`
	Count int    `json:"count"`
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
	PCoreCount       int       `json:"p_core_count"` // Performance cores (Intel hybrid), 0 elsewhere
	ECoreCount       int       `json:"e_core_count"` // Efficiency cores (Intel hybrid), 0 elsewhere
	// FreqAvgMHz and FreqMaxMHz are the mean and highest current clock across
	// online CPUs from cpufreq; 0 when the kernel exposes no cpufreq (most VMs).
	FreqAvgMHz float64 `json:"freq_avg_mhz"`
	FreqMaxMHz float64 `json:"freq_max_mhz"`
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
	Pressure    string  `json:"pressure"` // From PSI: normal/warn/critical; empty without /proc/pressure/memory
	// PSI is the raw Pressure Stall Information behind Pressure, nil when the
	// kernel does not provide it.
	PSI *MemoryPressureStats `json:"psi,omitempty"`
	// Zram sums the compressed RAM swap devices; nil when none holds data.
	Zram *ZramStatus `json:"zram,omitempty"`
}

// ZramStatus totals /sys/block/zram*/mm_stat, in bytes.
type ZramStatus struct {
	Devices    int     `json:"devices"`
	Original   uint64  `json:"original"`   // data stored, uncompressed
	Compressed uint64  `json:"compressed"` // the same data compressed
	MemUsed    uint64  `json:"mem_used"`   // RAM the devices take, allocator overhead included
	Ratio      float64 `json:"ratio"`      // Original / MemUsed
}

// MemoryPressureStats holds /proc/pressure/memory averages, in percent of time
// tasks were stalled on memory over the last 10 and 60 seconds.
type MemoryPressureStats struct {
	SomeAvg10 float64 `json:"some_avg10"`
	SomeAvg60 float64 `json:"some_avg60"`
	FullAvg10 float64 `json:"full_avg10"`
	FullAvg60 float64 `json:"full_avg60"`
}

type DiskStatus struct {
	Mount       string  `json:"mount"`
	Device      string  `json:"device"`
	Used        uint64  `json:"used"`
	Total       uint64  `json:"total"`
	UsedPercent float64 `json:"used_percent"`
	Fstype      string  `json:"fstype"`
	External    bool    `json:"external"`
	SmartStatus string  `json:"smart_status"`
	// Btrfs is chunk allocation for a btrfs volume; nil for other filesystems
	// or when /sys/fs/btrfs does not name the device.
	Btrfs *BtrfsAlloc `json:"btrfs,omitempty"`
}

type NetworkStatus struct {
	defaultTunnel bool    // Sample-local routing hint; not part of the JSON contract.
	defaultRoute  bool    // Carries the default route, tunnel or not; the IP line uses it, sort and totals use defaultTunnel.
	Name          string  `json:"name"`
	RxRateMBs     float64 `json:"rx_rate_mbs"`
	TxRateMBs     float64 `json:"tx_rate_mbs"`
	IP            string  `json:"ip"`
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
	// True when the only evidence is an active tunnel interface rather than a
	// configured proxy. A `utun` is equally iCloud Private Relay, a corporate
	// VPN, or a TUN-mode proxy client, and nothing at this layer can tell them
	// apart, so the reading must not be presented as "you have a proxy".
	IsTunnel bool `json:"-"`
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
	BatteryTemp  float64 `json:"battery_temp"` // Battery temperature in Celsius when power_supply exposes it
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

type Collector struct {
	// Static cache.
	cachedHW      HardwareInfo
	cachedRestart string
	lastHWAt      time.Time
	hasStatic     bool

	// Fast metrics (1s).
	prevNet             map[string]net.IOCountersStat
	lastNetAt           time.Time
	rxHistoryBuf        *RingBuffer
	txHistoryBuf        *RingBuffer
	lastNetIPAt         time.Time
	cachedNetIPs        map[string]string
	defaultNetInterface string
	lastGPUAt           time.Time
	cachedGPU           []GPUStatus
	gpuIdle             gpuIdleTracker
	prevDiskIO          disk.IOCountersStat
	lastDiskAt          time.Time

	watchMu           sync.Mutex
	processWatch      ProcessWatchConfig
	processWatcher    *ProcessWatcher
	enrichment        snapshotEnrichment
	hasEnrichment     bool
	processEnrichment processEnrichment
	hasProcessData    bool
}

type collectedMetrics struct {
	cpuStats                CPUStatus
	memStats                MemoryStatus
	diskStats               []DiskStatus
	trashSize               uint64
	trashApprox             bool
	diskIO                  DiskIOStatus
	netStats                []NetworkStatus
	proxyStats              ProxyStatus
	batteryStats            []BatteryStatus
	peripheralStats         []PeripheralBattery
	thermalStats            ThermalStatus
	sensorStats             []SensorReading
	gpuStats                []GPUStatus
	allProcs                []ProcessInfo
	hasProcesses            bool
	processParentsAvailable bool
	topApps                 []AppInfo
}

type snapshotEnrichment struct {
	// When adding MetricsSnapshot fields, update
	// TestMetricsSnapshotFieldsHaveCollectionClassifications.
	hardware       HardwareInfo
	memoryCached   uint64
	memoryPressure string
	memoryPSI      *MemoryPressureStats
	restartReason  string
	disks          []DiskStatus
	hasDisks       bool
	gpu            []GPUStatus
	trashSize      uint64
	trashApprox    bool
	proxy          ProxyStatus
	batteries      []BatteryStatus
	peripherals    []PeripheralBattery
	thermal        ThermalStatus
	sensors        []SensorReading
}

type processEnrichment struct {
	topProcesses          []ProcessInfo
	topApps               []AppInfo
	collectedAt           time.Time
	zombieCount           int
	zombieParents         []ZombieParent
	zombieParentsComplete bool
	processAlerts         []ProcessAlert
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

	snapshot := c.snapshotFromMetrics(now, hostInfo, collected)
	c.applyEnrichment(&snapshot, collected.hasProcesses)
	if collected.hasProcesses {
		c.cacheProcessEnrichment(snapshot)
	}
	return snapshot, mergeErr
}

func (c *Collector) Collect() (MetricsSnapshot, error) {
	return c.collectFull()
}

var (
	collectCPUFunc    = collectCPU
	collectMemoryFunc = collectMemory
)

func (c *Collector) collectFull() (MetricsSnapshot, error) {
	now := time.Now()
	hostInfo := collectHostInfo()
	var collected collectedMetrics
	// Each task owns its enrichment fields. If it returns an error or panics,
	// keep that group's previous values; publish after all tasks finish.
	next := c.enrichment

	// Sample CPU first, before the concurrent collectors below spawn their
	// work (disk and process reads, lspci, ...). The usage window is only
	// 100ms, so measuring while our own collection burst runs inflates the
	// reading with Mole's own load (#1237).
	var cpuErr error
	collected.cpuStats, cpuErr = collectCPUFunc()

	// Launch independent collection tasks.
	tasks := []func() error{
		func() error { return cpuErr },
		func() (err error) {
			collected.memStats, err = collectMemoryFunc()
			if err == nil {
				next.memoryCached = collected.memStats.Cached
				next.memoryPressure = collected.memStats.Pressure
				next.memoryPSI = collected.memStats.PSI
			}
			return
		},
		func() (err error) {
			collected.diskStats, err = collectDisks()
			if err == nil {
				next.disks = slices.Clone(collected.diskStats)
				next.hasDisks = true
			}
			return
		},
		func() error {
			collected.trashSize, collected.trashApprox = collectTrashSize()
			next.trashSize, next.trashApprox = collected.trashSize, collected.trashApprox
			return nil
		},
		func() (err error) { collected.diskIO = c.collectDiskIO(now); return nil },
		func() (err error) { collected.netStats = c.collectNetworkFull(now); return nil },
		func() error {
			collected.proxyStats = collectProxy()
			next.proxy = collected.proxyStats
			return nil
		},
		func() error {
			collected.batteryStats, _ = collectBatteries()
			next.batteries = slices.Clone(collected.batteryStats)
			collected.peripheralStats = collectPeripherals()
			next.peripherals = slices.Clone(collected.peripheralStats)
			return nil
		},
		func() error {
			collected.thermalStats = collectThermal()
			next.thermal = collected.thermalStats
			return nil
		},
		func() error {
			collected.sensorStats = collectSensors()
			next.sensors = slices.Clone(collected.sensorStats)
			return nil
		},
		func() (err error) {
			collected.gpuStats, err = c.collectGPU(now)
			if err == nil {
				next.gpu = slices.Clone(collected.gpuStats)
			}
			return
		},
		func() error { return collectProcessesInto(&collected) },
	}
	// Hardware info is expensive and rarely changes, so refresh it every 10
	// minutes. Its subprocesses join the burst instead of running after it.
	var hwStatic HardwareInfo
	var restartStatic string
	hwDone := false
	if !c.hasStatic || now.Sub(c.lastHWAt) > 10*time.Minute {
		tasks = append(tasks, func() error {
			hwStatic = collectHardwareStatic()
			restartStatic = detectRestartReason("/")
			hwDone = true
			return nil
		})
	}
	mergeErr := collectConcurrently(tasks...)
	if hwDone {
		c.cachedHW = finishHardware(hwStatic, collected.memStats.Total, collected.diskStats)
		c.cachedRestart = restartStatic
		c.lastHWAt = now
		c.hasStatic = true
	}

	snapshot := c.snapshotFromMetrics(now, hostInfo, collected)
	next.hardware = snapshot.Hardware
	next.restartReason = snapshot.RestartReason
	c.enrichment = next
	c.hasEnrichment = true
	c.applyEnrichment(&snapshot, collected.hasProcesses)
	if collected.hasProcesses {
		c.cacheProcessEnrichment(snapshot)
	}
	return snapshot, mergeErr
}

func collectProcessesInto(collected *collectedMetrics) error {
	sample, err := collectProcessesFunc()
	if err != nil {
		return err
	}
	collected.allProcs = sample.processes
	collected.topApps = buildTopApps(sample.root, sample.processes, time.Now())
	collected.hasProcesses = true
	collected.processParentsAvailable = sample.parentsAvailable
	return nil
}

func (c *Collector) snapshotFromMetrics(now time.Time, hostInfo *host.InfoStat, collected collectedMetrics) MetricsSnapshot {
	hwInfo := c.hardwareForSnapshot()

	score, scoreMsg := calculateHealthScore(
		collected.cpuStats,
		collected.memStats,
		collected.diskStats,
		collected.diskIO,
		collected.thermalStats,
		collected.batteryStats,
		c.cachedRestart,
	)
	var topProcs []ProcessInfo
	var processCollectedAt *time.Time
	var processStale *bool
	var zombieCount *int
	var zombieParents []ZombieParent
	var zombieParentsComplete *bool
	if collected.hasProcesses {
		topProcs = topProcesses(collected.allProcs, 5)
		processTime := now
		stale := false
		processCollectedAt = &processTime
		processStale = &stale
		count, parents, complete := summarizeZombies(
			collected.allProcs,
			zombieParentLimit,
			collected.processParentsAvailable,
		)
		zombieCount = &count
		zombieParents = parents
		zombieParentsComplete = &complete
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
		Platform:       strings.TrimSpace(hostInfo.Platform + " " + hostInfo.PlatformVersion), // rolling distros have no version
		Uptime:         formatUptime(hostInfo.Uptime),
		UptimeSeconds:  hostInfo.Uptime,
		Procs:          hostInfo.Procs,
		Hardware:       hwInfo,
		HealthScore:    score,
		HealthScoreMsg: scoreMsg,
		RestartReason:  c.cachedRestart,
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
		Proxy:                 collected.proxyStats,
		Batteries:             collected.batteryStats,
		Peripherals:           collected.peripheralStats,
		Thermal:               collected.thermalStats,
		Sensors:               collected.sensorStats,
		TopProcesses:          topProcs,
		TopApps:               collected.topApps,
		ProcessCollectedAt:    processCollectedAt,
		ProcessStale:          processStale,
		ZombieCount:           zombieCount,
		ZombieParents:         zombieParents,
		ZombieParentsComplete: zombieParentsComplete,
		ProcessWatch:          c.processWatch,
		ProcessAlerts:         processAlerts,
	}
}

func (c *Collector) hardwareForSnapshot() HardwareInfo {
	if c.hasStatic {
		return c.cachedHW
	}
	return HardwareInfo{}
}

func (c *Collector) cacheProcessEnrichment(snapshot MetricsSnapshot) {
	if snapshot.ZombieCount == nil {
		return
	}
	collectedAt := snapshot.CollectedAt
	if snapshot.ProcessCollectedAt != nil {
		collectedAt = *snapshot.ProcessCollectedAt
	}
	if collectedAt.IsZero() {
		return
	}
	complete := false
	if snapshot.ZombieParentsComplete != nil {
		complete = *snapshot.ZombieParentsComplete
	}
	c.processEnrichment = processEnrichment{
		topProcesses:          slices.Clone(snapshot.TopProcesses),
		topApps:               slices.Clone(snapshot.TopApps),
		collectedAt:           collectedAt,
		zombieCount:           *snapshot.ZombieCount,
		zombieParents:         slices.Clone(snapshot.ZombieParents),
		zombieParentsComplete: complete,
		processAlerts:         slices.Clone(snapshot.ProcessAlerts),
	}
	c.hasProcessData = true
}

func (c *Collector) applyEnrichment(snapshot *MetricsSnapshot, preserveLiveProcesses bool) {
	if snapshot == nil {
		return
	}
	if c.hasEnrichment {
		c.enrichment.apply(snapshot)
		snapshot.HealthScore, snapshot.HealthScoreMsg = calculateHealthScore(
			snapshot.CPU,
			snapshot.Memory,
			snapshot.Disks,
			snapshot.DiskIO,
			snapshot.Thermal,
			snapshot.Batteries,
			snapshot.RestartReason,
		)
	}
	if !preserveLiveProcesses && c.hasProcessData {
		c.processEnrichment.apply(snapshot)
	}
}

func (e snapshotEnrichment) apply(snapshot *MetricsSnapshot) {
	snapshot.Hardware = e.hardware
	snapshot.Memory.Cached = e.memoryCached
	snapshot.Memory.Pressure = e.memoryPressure
	snapshot.Memory.PSI = e.memoryPSI
	snapshot.RestartReason = e.restartReason
	// Disk capacity is slow-changing, so the fast path collects raw statfs
	// values and we overwrite them with the last full-refresh snapshot.
	// DiskIO stays live. Skip when the cache is empty so the first fast paint
	// still shows raw disks instead of a blank card.
	if e.hasDisks && len(e.disks) > 0 {
		snapshot.Disks = slices.Clone(e.disks)
	}
	snapshot.GPU = slices.Clone(e.gpu)
	snapshot.TrashSize = e.trashSize
	snapshot.TrashApprox = e.trashApprox
	snapshot.Proxy = e.proxy
	snapshot.Batteries = slices.Clone(e.batteries)
	snapshot.Peripherals = slices.Clone(e.peripherals)
	snapshot.Thermal = e.thermal
	snapshot.Sensors = slices.Clone(e.sensors)
}

func (e processEnrichment) apply(snapshot *MetricsSnapshot) {
	snapshot.TopProcesses = slices.Clone(e.topProcesses)
	snapshot.TopApps = slices.Clone(e.topApps)
	collectedAt := e.collectedAt
	stale := true
	snapshot.ProcessCollectedAt = &collectedAt
	snapshot.ProcessStale = &stale
	count := e.zombieCount
	complete := e.zombieParentsComplete
	snapshot.ZombieCount = &count
	snapshot.ZombieParents = slices.Clone(e.zombieParents)
	snapshot.ZombieParentsComplete = &complete
	snapshot.ProcessAlerts = slices.Clone(e.processAlerts)
}

var runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Env = cLocaleEnv()
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

// cLocaleEnv forces the C locale on every metric subprocess. ps and uptime
// localize their decimal separator, so under ru_RU.UTF-8 they emit "8,0" and
// every strconv.ParseFloat in the collectors fails (#1267). The shell commands
// in bin/ already export LC_ALL=C; status-go is exec'd directly and did not.
func cLocaleEnv() []string {
	env := os.Environ()
	filtered := make([]string, 0, len(env)+1)
	for _, kv := range env {
		key, _, found := strings.Cut(kv, "=")
		if found && (key == "LC_ALL" || key == "LANG" || strings.HasPrefix(key, "LC_")) {
			continue
		}
		filtered = append(filtered, kv)
	}
	return append(filtered, "LC_ALL=C")
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
