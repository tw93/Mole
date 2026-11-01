package main

import (
	"testing"

	"github.com/shirou/gopsutil/v4/disk"
)

func dmiTree(t *testing.T, vendor, product, version string) string {
	t.Helper()
	return writeTree(t, map[string]string{
		"sys/class/dmi/id/sys_vendor":      vendor + "\n",
		"sys/class/dmi/id/product_name":    product + "\n",
		"sys/class/dmi/id/product_version": version + "\n",
	})
}

func TestReadDMIModelFiltersPlaceholders(t *testing.T) {
	tests := []struct {
		name                     string
		vendor, product, version string
		want                     string
	}{
		{"real laptop", "LENOVO", "20XW00ABCD", "ThinkPad X1 Carbon Gen 9", "LENOVO 20XW00ABCD ThinkPad X1 Carbon Gen 9"},
		{"vendor repeated in product", "Dell Inc.", "Dell Inc. XPS 13 9310", "", "Dell Inc. XPS 13 9310"},
		{"board with only placeholders", "Default string", "Default string", "Default string", ""},
		{"oem placeholders", "To be filled by O.E.M.", "To be filled by O.E.M.", "To be filled by O.E.M.", ""},
		{"asus desktop placeholder", "System manufacturer", "System Product Name", "System Version", ""},
		{"placeholder product keeps real vendor", "ASUSTeK COMPUTER INC.", "System Product Name", "", "ASUSTeK COMPUTER INC."},
		{"qemu vendor alone", "QEMU", "", "", ""},
		{"qemu vendor with unknown fields", "QEMU", "Unknown", "Not Specified", ""},
		{"qemu with real description", "QEMU", "Standard PC (Q35 + ICH9, 2009)", "pc-q35-8.1", "QEMU Standard PC (Q35 + ICH9, 2009)"},
		{"numeric version dropped", "Acme", "Widget", "1.0", "Acme Widget"},
		{"empty", "", "", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := dmiTree(t, tt.vendor, tt.product, tt.version)
			if got := readHardwareInfo(root).Model; got != tt.want {
				t.Fatalf("Model = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestReadDMIModelMissingFiles(t *testing.T) {
	if got := readHardwareInfo(t.TempDir()); got != (HardwareInfo{}) {
		t.Fatalf("readHardwareInfo(empty root) = %#v, want zero value so the header shows nothing", got)
	}
}

func TestReadCPUModelAndOSVersion(t *testing.T) {
	root := writeTree(t, map[string]string{
		"proc/cpuinfo":              "processor\t: 0\nvendor_id\t: GenuineIntel\nmodel name\t: 11th Gen   Intel(R) Core(TM) i7-1185G7 @ 3.00GHz\n\nprocessor\t: 1\nmodel name\t: other\n",
		"etc/os-release":            "NAME=\"Arch Linux\"\nPRETTY_NAME=\"Arch Linux\"\nID=arch\n",
		"proc/sys/kernel/osrelease": "6.12.1-arch1-1\n",
	})
	hw := readHardwareInfo(root)
	if hw.CPUModel != "11th Gen Intel(R) Core(TM) i7-1185G7 @ 3.00GHz" {
		t.Fatalf("CPUModel = %q", hw.CPUModel)
	}
	if hw.OSVersion != "Arch Linux, kernel 6.12.1-arch1-1" {
		t.Fatalf("OSVersion = %q", hw.OSVersion)
	}
}

func TestReadCPUModelARMFallsBackToModelThenEmpty(t *testing.T) {
	root := writeTree(t, map[string]string{
		"proc/cpuinfo": "processor\t: 0\nBogoMIPS\t: 108.00\n\nHardware\t: BCM2835\nModel\t\t: Raspberry Pi 4 Model B Rev 1.4\n",
	})
	if got := readCPUModel(root + "/proc/cpuinfo"); got != "BCM2835" {
		t.Fatalf("readCPUModel() = %q, want first fallback key (Hardware)", got)
	}
	bare := writeTree(t, map[string]string{"proc/cpuinfo": "processor\t: 0\n"})
	if got := readCPUModel(bare + "/proc/cpuinfo"); got != "" {
		t.Fatalf("readCPUModel() = %q, want empty rather than the architecture", got)
	}
}

func TestReadOSVersionFallbacks(t *testing.T) {
	usrLib := writeTree(t, map[string]string{
		"usr/lib/os-release": "PRETTY_NAME='Debian GNU/Linux 12 (bookworm)'\n",
	})
	if got := readOSVersion(usrLib); got != "Debian GNU/Linux 12 (bookworm)" {
		t.Fatalf("readOSVersion() = %q", got)
	}
	kernelOnly := writeTree(t, map[string]string{"proc/sys/kernel/osrelease": "5.15.0\n"})
	if got := readOSVersion(kernelOnly); got != "Linux 5.15.0" {
		t.Fatalf("readOSVersion() = %q", got)
	}
}

func TestFinishHardwareUsesRootFilesystemSize(t *testing.T) {
	disks := []DiskStatus{
		{Mount: "/data", Total: 4 << 40},
		{Mount: "/", Total: 512 << 30},
	}
	hw := finishHardware(HardwareInfo{}, 8<<30, disks)
	if hw.DiskSize != humanBytes(512<<30) || hw.TotalRAM != humanBytes(8<<30) {
		t.Fatalf("finishHardware() = %+v", hw)
	}

	orig := diskUsageFunc
	t.Cleanup(func() { diskUsageFunc = orig })
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Path: path, Total: 100 << 30}, nil
	}
	hw = finishHardware(HardwareInfo{}, 0, nil)
	if hw.DiskSize != humanBytes(100<<30) || hw.TotalRAM != "" {
		t.Fatalf("finishHardware() without disks = %+v, want statfs size and no RAM filler", hw)
	}
}

// The full collection fills RAM and root-disk size from the same burst that
// measured them, and reuses the card inside the 10 minute window.
func TestCollectFullFillsHardwareAndCachesIt(t *testing.T) {
	origPartitions, origUsage := diskPartitionsFunc, diskUsageFunc
	origCPU, origMemory, origProcesses := collectCPUFunc, collectMemoryFunc, collectProcessesFunc
	t.Cleanup(func() {
		diskPartitionsFunc, diskUsageFunc = origPartitions, origUsage
		collectCPUFunc, collectMemoryFunc, collectProcessesFunc = origCPU, origMemory, origProcesses
	})
	t.Setenv("HOME", t.TempDir())

	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{{Device: "/dev/vda2", Mountpoint: "/", Fstype: "ext4"}}, nil
	}
	diskUsageFunc = func(string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Total: 2 << 30, Used: 1 << 30, Free: 1 << 30, UsedPercent: 50}, nil
	}
	collectCPUFunc = func() (CPUStatus, error) { return CPUStatus{LogicalCPU: 2}, nil }
	collectMemoryFunc = func() (MemoryStatus, error) { return MemoryStatus{Total: 8 << 30}, nil }
	collectProcessesFunc = func() (processSample, error) { return processSample{}, nil }

	collector := NewCollector(ProcessWatchOptions{})
	snapshot, _ := collector.Collect()
	hw := snapshot.Hardware
	if hw.TotalRAM != humanBytes(8<<30) || hw.DiskSize != humanBytes(2<<30) {
		t.Fatalf("hardware info = %+v", hw)
	}

	collector.cachedHW.OSVersion = "cached marker"
	again, _ := collector.Collect()
	if again.Hardware.OSVersion != "cached marker" {
		t.Fatalf("hardware was re-read inside the cache window: %+v", again.Hardware)
	}
}
