package metrics

import "time"

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
		copy(res, rb.data[rb.index:])
		copy(res[rb.cap-rb.index:], rb.data[:rb.index])
	}
	return res
}

type MetricsSnapshot struct {
	CollectedAt    time.Time
	Host           string
	Platform       string
	Uptime         string
	Procs          uint64
	Hardware       HardwareInfo
	HealthScore    int    // 0-100 system health score
	HealthScoreMsg string // Brief explanation

	CPU            CPUStatus
	GPU            []GPUStatus
	Memory         MemoryStatus
	Disks          []DiskStatus
	DiskIO         DiskIOStatus
	Network        []NetworkStatus
	NetworkHistory NetworkHistory
	Proxy          ProxyStatus
	Batteries      []BatteryStatus
	Thermal        ThermalStatus
	Bluetooth      []BluetoothDevice
	TopProcesses   []ProcessInfo
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

// NetworkHistory holds the global network usage history.
type NetworkHistory struct {
	RxHistory []float64
	TxHistory []float64
}

// NetworkHistorySize is the number of samples retained per interface (~2 min at 1s intervals).
const NetworkHistorySize = 120

type ProxyStatus struct {
	Enabled bool
	Type    string // HTTP, HTTPS, SOCKS, PAC, WPAD, TUN
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

type BluetoothDevice struct {
	Name      string
	Connected bool
	Battery   string
}
