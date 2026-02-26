// Package metrics provides system metrics collection shared by status and menubar commands.
package metrics

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

	// Core topology cache (moved from package-level).
	lastTopologyAt   time.Time
	cachedP, cachedE int

	// Power data cache (moved from package-level).
	lastPowerAt time.Time
	cachedPower string

	// Disk type cache (moved from package-level).
	lastDiskCacheAt time.Time
	diskTypeCache   map[string]bool
}

func NewCollector() *Collector {
	return &Collector{
		prevNet:       make(map[string]net.IOCountersStat),
		rxHistoryBuf:  NewRingBuffer(NetworkHistorySize),
		txHistoryBuf:  NewRingBuffer(NetworkHistorySize),
		diskTypeCache: make(map[string]bool),
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
	collect(func() (err error) { cpuStats, err = c.collectCPU(); return })
	collect(func() (err error) { memStats, err = collectMemory(); return })
	collect(func() (err error) { diskStats, err = c.collectDisks(); return })
	collect(func() (err error) { diskIO = c.collectDiskIO(now); return nil })
	collect(func() (err error) { netStats, err = c.collectNetwork(now); return })
	collect(func() (err error) { proxyStats = collectProxy(); return nil })
	collect(func() (err error) { batteryStats, _ = c.collectBatteries(); return nil })
	collect(func() (err error) { thermalStats = c.collectThermal(); return nil })
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

	score, scoreMsg := CalculateHealthScore(cpuStats, memStats, diskStats, diskIO, thermalStats)

	return MetricsSnapshot{
		CollectedAt:    now,
		Host:           hostInfo.Hostname,
		Platform:       fmt.Sprintf("%s %s", hostInfo.Platform, hostInfo.PlatformVersion),
		Uptime:         FormatUptime(hostInfo.Uptime),
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
		NetworkHistory: NetworkHistory{
			RxHistory: c.rxHistoryBuf.Slice(),
			TxHistory: c.txHistoryBuf.Slice(),
		},
		Proxy:        proxyStats,
		Batteries:    batteryStats,
		Thermal:      thermalStats,
		Bluetooth:    btStats,
		TopProcesses: topProcs,
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
