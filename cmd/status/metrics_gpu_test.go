package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// drmFixture builds /sys/class/drm/cardN/device as a symlink to a PCI slot
// directory, the way the kernel lays it out.
func drmFixture(t *testing.T, cards map[string]string, vendors map[string]string, extra map[string]string) string {
	t.Helper()
	root := t.TempDir()
	for card, slot := range cards {
		pci := filepath.Join(root, "sys/devices/pci0000:00", "0000:"+slot)
		if err := os.MkdirAll(pci, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(pci, "vendor"), []byte(vendors[card]+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		cardDir := filepath.Join(root, "sys/class/drm", card)
		if err := os.MkdirAll(cardDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(pci, filepath.Join(cardDir, "device")); err != nil {
			t.Fatal(err)
		}
	}
	addTree(t, root, extra)
	return root
}

func TestReadGPUsNamesFromLspciAndVendor(t *testing.T) {
	root := drmFixture(t,
		map[string]string{"card0": "00:02.0", "card1": "01:00.0", "card0-HDMI-A-1": "00:02.0"},
		map[string]string{"card0": "0x8086", "card1": "0x10de", "card0-HDMI-A-1": "0x8086"},
		nil)
	names := func() map[string]string {
		return parseLspciDisplays(`00:02.0 "VGA compatible controller" "Intel Corporation" "Alder Lake-P GT2 [Iris Xe Graphics]" -r0c -p00 "Lenovo" "Device 22d2"
00:1f.3 "Audio device" "Intel Corporation" "Alder Lake PCH-P High Definition Audio" -r01 -p80 "Lenovo" "Device 22d2"
`)
	}
	got := readGPUs(root, names)
	if len(got) != 2 {
		t.Fatalf("readGPUs() = %#v, want two cards (connector entries ignored)", got)
	}
	if got[0].Name != "Intel Iris Xe Graphics" {
		t.Fatalf("card0 name = %q, want vendor + lspci marketing name", got[0].Name)
	}
	if got[1].Name != "NVIDIA graphics" {
		t.Fatalf("card1 name = %q, want vendor-only name without lspci data", got[1].Name)
	}
	if got[0].Usage != -1 {
		t.Fatalf("usage = %v, want -1 (unknown)", got[0].Usage)
	}
}

func TestReadGPUsWithoutDRMOrUnknownVendorIsEmpty(t *testing.T) {
	if got := readGPUs(t.TempDir(), nil); len(got) != 0 {
		t.Fatalf("readGPUs(no drm) = %#v, want none", got)
	}
	root := drmFixture(t, map[string]string{"card0": "00:02.0"}, map[string]string{"card0": "0xdead"}, nil)
	if got := readGPUs(root, nil); len(got) != 0 {
		t.Fatalf("readGPUs(unknown vendor) = %#v, want none rather than filler", got)
	}
}

func TestRefreshGPUUsageReadsGpuBusyPercent(t *testing.T) {
	root := drmFixture(t, map[string]string{"card0": "03:00.0"}, map[string]string{"card0": "0x1002"},
		map[string]string{"sys/devices/pci0000:00/0000:03:00.0/gpu_busy_percent": "37\n"})
	gpus := readGPUs(root, nil)
	refreshGPUUsage(root, gpus, nil, time.Now())
	if len(gpus) != 1 || gpus[0].Usage != 37 || gpus[0].Name != "AMD graphics" {
		t.Fatalf("gpus = %#v, want AMD at 37%%", gpus)
	}
}

func TestParseLspciDisplaysKeepsOnlyDisplayClasses(t *testing.T) {
	got := parseLspciDisplays(`0000:00:02.0 "VGA compatible controller" "Red Hat, Inc." "Virtio 1.0 GPU" -r01
00:03.0 "3D controller" "NVIDIA Corporation" "GA107M [GeForce RTX 3050 Mobile]" -ra1
00:04.0 "Ethernet controller" "Intel Corporation" "I219-LM" -r00
`)
	if got["00:02.0"] != "Virtio 1.0 GPU" || got["00:03.0"] != "GeForce RTX 3050 Mobile" || len(got) != 2 {
		t.Fatalf("parseLspciDisplays() = %#v", got)
	}
}

func TestRefreshGPUUsageLeavesSuspendedCardAsleep(t *testing.T) {
	root := drmFixture(t, map[string]string{"card1": "01:00.0"}, map[string]string{"card1": "0x1002"},
		map[string]string{
			"sys/devices/pci0000:00/0000:01:00.0/gpu_busy_percent":     "88\n",
			"sys/devices/pci0000:00/0000:01:00.0/power/runtime_status": "suspended\n",
		})
	gpus := readGPUs(root, nil)
	refreshGPUUsage(root, gpus, nil, time.Now())
	if len(gpus) != 1 || gpus[0].Usage != 0 || gpus[0].Note != "suspended" {
		t.Fatalf("gpus = %#v, want a sleeping card reported idle without reading it", gpus)
	}
}

func TestRefreshGPUUsageQueriesEachNvidiaCardByBusID(t *testing.T) {
	root := drmFixture(t,
		map[string]string{"card0": "01:00.0", "card1": "02:00.0"},
		map[string]string{"card0": pciVendorNVIDIA, "card1": pciVendorNVIDIA},
		nil)
	origRun, origExists := runCmd, commandExists
	t.Cleanup(func() { runCmd, commandExists = origRun, origExists })
	commandExists = func(name string) bool { return name == "nvidia-smi" }
	var asked []string
	runCmd = func(_ context.Context, name string, args ...string) (string, error) {
		id := strings.TrimPrefix(args[0], "--id=")
		asked = append(asked, id)
		// nvidia-smi answers for the requested card only.
		switch id {
		case "00000000:01:00.0":
			return "00000000:01:00.0, 10, 500, 8192, RTX A\n", nil
		case "00000000:02:00.0":
			return "00000000:02:00.0, 70, 6000, 24576, RTX B\n", nil
		}
		return "", errors.New("no such gpu")
	}
	gpus := readGPUs(root, nil)
	refreshGPUUsage(root, gpus, nil, time.Now())
	if len(asked) != 2 || gpus[0].Name != "RTX A" || gpus[0].Usage != 10 || gpus[1].Name != "RTX B" || gpus[1].Usage != 70 || gpus[1].MemoryTotal != 24576 {
		t.Fatalf("asked %q, gpus = %#v, want each card its own line", asked, gpus)
	}

	var g GPUStatus
	parseNvidiaSMI(&g, "00000000:02:00.0", "00000000:01:00.0, 99, 1, 2, Wrong\n")
	if g.Name != "" || g.Usage != 0 {
		t.Fatalf("a line for another bus id was applied: %#v", g)
	}
}

func TestRefreshGPUUsageDerivesIntelBusyFromIdleResidency(t *testing.T) {
	root := drmFixture(t, map[string]string{"card0": "00:02.0"}, map[string]string{"card0": "0x8086"},
		map[string]string{"sys/class/drm/card0/gt/gt0/rc6_residency_ms": "1000\n"})
	gpus := readGPUs(root, nil)
	idle := gpuIdleTracker{}
	start := time.Now()
	refreshGPUUsage(root, gpus, idle, start)
	if gpus[0].Usage != -1 {
		t.Fatalf("first reading = %v, want -1 until a second sample exists", gpus[0].Usage)
	}
	addTree(t, root, map[string]string{"sys/class/drm/card0/gt/gt0/rc6_residency_ms": "1750\n"})
	refreshGPUUsage(root, gpus, idle, start.Add(time.Second))
	if gpus[0].Usage != 25 {
		t.Fatalf("busy = %v, want 25 (750 ms idle in 1 s)", gpus[0].Usage)
	}

	xe := drmFixture(t, map[string]string{"card0": "00:02.0"}, map[string]string{"card0": "0x8086"},
		map[string]string{"sys/devices/pci0000:00/0000:00:02.0/tile0/gt0/gtidle/idle_residency_ms": "5000\n"})
	card := listDRMGPUs(xe)[0]
	if ms, ok := intelIdleResidencyMS(card); !ok || ms != 5000 {
		t.Fatalf("xe idle residency = %v, %v", ms, ok)
	}
}
