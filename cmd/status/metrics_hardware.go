package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// collectHardwareStatic reads the slow-changing identity of the machine from
// procfs, sysfs and /etc. Every source is a plain file read, so it can run
// inside collectFull's concurrent burst without spawning a process. Fields it
// cannot establish stay empty and the header hides them.
func collectHardwareStatic() HardwareInfo {
	return readHardwareInfo("/")
}

// readHardwareInfo reads under root so tests can point it at a fixture tree.
func readHardwareInfo(root string) HardwareInfo {
	return HardwareInfo{
		Model:     readDMIModel(filepath.Join(root, "sys/class/dmi/id")),
		CPUModel:  readCPUModel(filepath.Join(root, "proc/cpuinfo")),
		OSVersion: readOSVersion(root),
	}
}

// finishHardware fills the fields that depend on the memory and disk results
// of the same collection burst. DiskSize is the size of the root filesystem.
func finishHardware(hw HardwareInfo, totalRAM uint64, disks []DiskStatus) HardwareInfo {
	if totalRAM > 0 {
		hw.TotalRAM = humanBytes(totalRAM)
	}
	if disk, ok := rootMountDisk(disks); ok && disk.Total > 0 {
		hw.DiskSize = humanBytes(disk.Total)
	} else if usage, err := diskUsageFunc("/"); err == nil && usage.Total > 0 {
		hw.DiskSize = humanBytes(usage.Total)
	}
	return hw
}

func rootMountDisk(disks []DiskStatus) (DiskStatus, bool) {
	for _, d := range disks {
		if d.Mount == "/" {
			return d, true
		}
	}
	return DiskStatus{}, false
}

// dmiPlaceholders are the strings firmware vendors leave in DMI fields they
// never filled in. They carry no information, so they count as unknown.
var dmiPlaceholders = map[string]bool{
	"":                       true,
	"default string":         true,
	"to be filled by o.e.m.": true,
	"to be filled by oem":    true,
	"system product name":    true,
	"system manufacturer":    true,
	"system version":         true,
	"not specified":          true,
	"not applicable":         true,
	"none":                   true,
	"unknown":                true,
	"n/a":                    true,
	"o.e.m.":                 true,
	"oem":                    true,
}

// versionNoise matches product_version values such as "1.0", "A1" or the QEMU
// machine type "pc-q35-8.1" that say nothing about the model.
var versionNoise = regexp.MustCompile(`^([A-Za-z]?[0-9][0-9.\-]*|pc-(q35|i440fx)[0-9a-z.\-]*)$`)

func cleanDMIValue(raw string) string {
	value := strings.Join(strings.Fields(raw), " ")
	if dmiPlaceholders[strings.ToLower(value)] {
		return ""
	}
	return value
}

// readDMIModel joins sys_vendor, product_name and product_version, dropping
// placeholders and repeated words. A lone "QEMU" vendor names no model, but
// "QEMU Standard PC (Q35 + ICH9, 2009)" is a real description of the VM.
func readDMIModel(dir string) string {
	vendor := cleanDMIValue(readTrimmed(filepath.Join(dir, "sys_vendor")))
	product := cleanDMIValue(readTrimmed(filepath.Join(dir, "product_name")))
	version := cleanDMIValue(readTrimmed(filepath.Join(dir, "product_version")))

	if versionNoise.MatchString(version) {
		version = ""
	}
	parts := []string{}
	add := func(s string) {
		if s == "" {
			return
		}
		lower := strings.ToLower(strings.Join(parts, " "))
		if strings.Contains(lower, strings.ToLower(s)) {
			return
		}
		parts = append(parts, s)
	}
	if vendor != "" && product != "" && strings.HasPrefix(strings.ToLower(product), strings.ToLower(vendor)) {
		vendor = ""
	}
	add(vendor)
	add(product)
	add(version)
	// A bare hypervisor vendor names no model.
	if len(parts) == 1 && strings.EqualFold(parts[0], "qemu") {
		return ""
	}
	return strings.Join(parts, " ")
}

// readCPUModel returns the first "model name" of /proc/cpuinfo. ARM kernels
// have no such key, so fall back to "Model" or "Hardware" and otherwise stay
// empty.
func readCPUModel(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	fallback := ""
	for line := range strings.Lines(string(data)) {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		value = strings.Join(strings.Fields(value), " ")
		if value == "" {
			continue
		}
		switch key {
		case "model name":
			return value
		case "Model", "Hardware":
			if fallback == "" {
				fallback = value
			}
		}
	}
	return fallback
}

// readOSVersion renders "<PRETTY_NAME>, kernel <release>" from
// /etc/os-release (or /usr/lib/os-release) and the running kernel release.
func readOSVersion(root string) string {
	name := ""
	for _, rel := range []string{"etc/os-release", "usr/lib/os-release"} {
		data, err := os.ReadFile(filepath.Join(root, rel))
		if err != nil {
			continue
		}
		name = parseOSReleasePrettyName(string(data))
		if name != "" {
			break
		}
	}
	kernel := readTrimmed(filepath.Join(root, "proc/sys/kernel/osrelease"))
	switch {
	case name != "" && kernel != "":
		return name + ", kernel " + kernel
	case name != "":
		return name
	case kernel != "":
		return "Linux " + kernel
	}
	return ""
}

func parseOSReleasePrettyName(raw string) string {
	for line := range strings.Lines(raw) {
		value, ok := strings.CutPrefix(strings.TrimSpace(line), "PRETTY_NAME=")
		if !ok {
			continue
		}
		return strings.TrimSpace(strings.Trim(strings.TrimSpace(value), `"'`))
	}
	return ""
}

func readTrimmed(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}
