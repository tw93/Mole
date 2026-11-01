package main

import (
	"os"
	"path/filepath"
	"testing"
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
	refreshGPUUsage(root, gpus)
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
