package main

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Temperatures outside (0, 125] C are driver glitches (0 for an unwired
// channel, -128 or 255 for a failed read), not readings.
const (
	maxSaneTempC  = 125.0
	maxSaneFanRPM = 30000
)

func validTempC(c float64) bool { return c > 0 && c <= maxSaneTempC }

type hwmonTemp struct {
	index int
	label string
	value float64
}

type hwmonFan struct {
	index int
	rpm   int
}

type hwmonDevice struct {
	name  string
	temps []hwmonTemp
	fans  []hwmonFan
}

// Driver priority when several devices could describe the CPU or GPU.
var (
	cpuHwmonDrivers = []string{"coretemp", "k10temp", "zenpower", "cpu_thermal", "cpu-thermal"}
	gpuHwmonDrivers = []string{"amdgpu", "nouveau", "nvidia", "i915", "xe"}
	// Labels naming the package or die sensor, best first. Matching is by
	// lower-case prefix ("package id 0", "tdie", "tctl").
	cpuTempLabels = []string{"package id", "tdie", "tctl", "cpu", "tccd"}
	gpuTempLabels = []string{"edge", "gpu", "pkg", "junction"}
	// Thermal zone types that are the CPU package.
	cpuThermalZoneTypes = []string{"x86_pkg_temp", "cpu", "cpu-thermal", "cpu_thermal"}
)

func collectThermal() ThermalStatus {
	return readThermal("/")
}

// readThermal builds ThermalStatus from hwmon, falling back to thermal zones
// for the CPU and reading the battery temperature and fans on the side.
func readThermal(root string) ThermalStatus {
	devices := readHwmon(root)
	var thermal ThermalStatus

	thermal.CPUTemp = pickTemp(devices, cpuHwmonDrivers, cpuTempLabels)
	if thermal.CPUTemp == 0 {
		thermal.CPUTemp = readThermalZoneCPU(root)
	}
	thermal.GPUTemp = pickTemp(devices, gpuHwmonDrivers, gpuTempLabels)
	thermal.BatteryTemp = readBatteryTemp(root)
	readPower(root, &thermal)

	for _, d := range devices {
		for _, f := range d.fans {
			thermal.FanCount++
			thermal.FanSpeed = max(thermal.FanSpeed, f.rpm)
		}
	}
	return thermal
}

// collectSensors lists every sane hwmon temperature and fan for the JSON
// output. The TUI keeps its Sensors card hidden because the CPU card already
// shows the temperature.
func collectSensors() []SensorReading {
	return readSensors("/")
}

func readSensors(root string) []SensorReading {
	var out []SensorReading
	for _, d := range readHwmon(root) {
		for _, t := range d.temps {
			label := t.label
			if label == "" {
				label = "temp" + strconv.Itoa(t.index)
			}
			out = append(out, SensorReading{Label: label, Value: t.value, Unit: "°C", Note: d.name})
		}
		for _, f := range d.fans {
			out = append(out, SensorReading{Label: "fan" + strconv.Itoa(f.index), Value: float64(f.rpm), Unit: "RPM", Note: d.name})
		}
	}
	return out
}

func readHwmon(root string) []hwmonDevice {
	dirs, _ := filepath.Glob(filepath.Join(root, "sys/class/hwmon/hwmon*"))
	sort.Slice(dirs, func(i, j int) bool { return naturalLess(dirs[i], dirs[j]) })

	var devices []hwmonDevice
	for _, dir := range dirs {
		name := readTrimmed(filepath.Join(dir, "name"))
		if name == "" {
			continue
		}
		dev := hwmonDevice{name: name}
		// Current kernels put the channel files in the hwmon directory; some
		// older drivers keep them under device/.
		for _, src := range []string{dir, filepath.Join(dir, "device")} {
			dev.temps = append(dev.temps, readHwmonTemps(src)...)
			dev.fans = append(dev.fans, readHwmonFans(src)...)
			if len(dev.temps)+len(dev.fans) > 0 {
				break
			}
		}
		if len(dev.temps)+len(dev.fans) > 0 {
			devices = append(devices, dev)
		}
	}
	return devices
}

func readHwmonTemps(dir string) []hwmonTemp {
	files, _ := filepath.Glob(filepath.Join(dir, "temp*_input"))
	var temps []hwmonTemp
	for _, f := range files {
		base := filepath.Base(f)
		idx, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(base, "temp"), "_input"))
		if err != nil {
			continue
		}
		milli, ok := readInt(f)
		if !ok {
			continue
		}
		c := float64(milli) / 1000
		if !validTempC(c) {
			continue
		}
		label := readTrimmed(filepath.Join(dir, "temp"+strconv.Itoa(idx)+"_label"))
		temps = append(temps, hwmonTemp{index: idx, label: label, value: c})
	}
	sort.Slice(temps, func(i, j int) bool { return temps[i].index < temps[j].index })
	return temps
}

func readHwmonFans(dir string) []hwmonFan {
	files, _ := filepath.Glob(filepath.Join(dir, "fan*_input"))
	var fans []hwmonFan
	for _, f := range files {
		base := filepath.Base(f)
		idx, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(base, "fan"), "_input"))
		if err != nil {
			continue
		}
		rpm, ok := readInt(f)
		if !ok || rpm <= 0 || rpm > maxSaneFanRPM {
			continue
		}
		fans = append(fans, hwmonFan{index: idx, rpm: int(rpm)})
	}
	sort.Slice(fans, func(i, j int) bool { return fans[i].index < fans[j].index })
	return fans
}

// pickTemp returns the reading of the first driver in priority order that has
// one: the best-labelled channel across that driver's devices, else the
// hottest channel.
func pickTemp(devices []hwmonDevice, drivers, labels []string) float64 {
	for _, driver := range drivers {
		var matching []hwmonDevice
		for _, d := range devices {
			if d.name == driver {
				matching = append(matching, d)
			}
		}
		if len(matching) == 0 {
			continue
		}
		for _, want := range labels {
			best := 0.0
			for _, d := range matching {
				for _, t := range d.temps {
					if strings.HasPrefix(strings.ToLower(t.label), want) {
						best = max(best, t.value)
					}
				}
			}
			if best > 0 {
				return best
			}
		}
		hottest := 0.0
		for _, d := range matching {
			for _, t := range d.temps {
				hottest = max(hottest, t.value)
			}
		}
		if hottest > 0 {
			return hottest
		}
	}
	return 0
}

func readThermalZoneCPU(root string) float64 {
	zones, _ := filepath.Glob(filepath.Join(root, "sys/class/thermal/thermal_zone*"))
	sort.Slice(zones, func(i, j int) bool { return naturalLess(zones[i], zones[j]) })
	for _, zone := range zones {
		typ := strings.ToLower(readTrimmed(filepath.Join(zone, "type")))
		wanted := false
		for _, t := range cpuThermalZoneTypes {
			if typ == t {
				wanted = true
				break
			}
		}
		if !wanted {
			continue
		}
		if milli, ok := readInt(filepath.Join(zone, "temp")); ok {
			if c := float64(milli) / 1000; validTempC(c) {
				return c
			}
		}
	}
	return 0
}

// naturalLess orders hwmon2 before hwmon10.
func naturalLess(a, b string) bool {
	if len(a) != len(b) {
		return len(a) < len(b)
	}
	return a < b
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}
