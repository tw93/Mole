package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// collectBatteries lists the machine's own batteries (and UPS units) from
// /sys/class/power_supply. A desktop without any returns an empty slice and
// the Power card is hidden.
func collectBatteries() ([]BatteryStatus, error) {
	return readBatteries("/"), nil
}

type powerSupply struct {
	dir      string
	typ      string
	scope    string
	online   bool
	hasOnl   bool
	notReady bool // present=0: the bay is empty
}

func listPowerSupplies(root string) []powerSupply {
	base := filepath.Join(root, "sys/class/power_supply")
	entries, err := os.ReadDir(base)
	if err != nil {
		return nil
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)

	supplies := make([]powerSupply, 0, len(names))
	for _, name := range names {
		dir := filepath.Join(base, name)
		ps := powerSupply{
			dir:   dir,
			typ:   readTrimmed(filepath.Join(dir, "type")),
			scope: readTrimmed(filepath.Join(dir, "scope")),
		}
		if v := readTrimmed(filepath.Join(dir, "online")); v != "" {
			ps.hasOnl = true
			ps.online = v == "1"
		}
		ps.notReady = readTrimmed(filepath.Join(dir, "present")) == "0"
		supplies = append(supplies, ps)
	}
	return supplies
}

func acOnline(supplies []powerSupply) bool {
	for _, ps := range supplies {
		if ps.typ == "Battery" || ps.typ == "UPS" || ps.scope == "Device" {
			continue
		}
		if ps.hasOnl && ps.online {
			return true
		}
	}
	return false
}

// readBatteries parses every Battery or UPS supply under root. Supplies with
// scope=Device (a wireless mouse, a stylus) belong to peripherals, not to this
// machine; readPeripherals lists them.
func readBatteries(root string) []BatteryStatus {
	supplies := listPowerSupplies(root)
	ac := acOnline(supplies)

	var out []BatteryStatus
	for _, ps := range supplies {
		if !machineBattery(ps) {
			continue
		}
		if b, ok := parseBattery(ps.dir, ac); ok {
			out = append(out, b)
		}
	}
	return out
}

func readInt(path string) (int64, bool) {
	raw := readTrimmed(path)
	if raw == "" {
		return 0, false
	}
	v, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func parseBattery(dir string, ac bool) (BatteryStatus, bool) {
	// Energy (uWh, uW) is preferred; charge (uAh, uA) is the same shape for
	// drivers that cannot report energy. Ratios between them are unit-free.
	now, _ := readInt(filepath.Join(dir, "energy_now"))
	full, _ := readInt(filepath.Join(dir, "energy_full"))
	design, _ := readInt(filepath.Join(dir, "energy_full_design"))
	rate, _ := readInt(filepath.Join(dir, "power_now"))
	if full <= 0 {
		now, _ = readInt(filepath.Join(dir, "charge_now"))
		full, _ = readInt(filepath.Join(dir, "charge_full"))
		design, _ = readInt(filepath.Join(dir, "charge_full_design"))
		rate, _ = readInt(filepath.Join(dir, "current_now"))
	}
	if rate < 0 {
		rate = -rate
	}

	percent := -1.0
	if v, ok := readInt(filepath.Join(dir, "capacity")); ok && v >= 0 && v <= 100 {
		percent = float64(v)
	} else if full > 0 && now >= 0 {
		percent = math.Min(100, float64(now)*100/float64(full))
	}
	if percent < 0 {
		return BatteryStatus{}, false
	}

	status := normalizeBatteryStatus(readTrimmed(filepath.Join(dir, "status")), ac)
	b := BatteryStatus{Percent: percent, Status: status}

	if full > 0 && design > 0 {
		b.Capacity = int(math.Min(100, math.Round(float64(full)*100/float64(design))))
	}
	if cycles, ok := readInt(filepath.Join(dir, "cycle_count")); ok && cycles > 0 {
		b.CycleCount = int(cycles)
	}
	if health := readTrimmed(filepath.Join(dir, "health")); health != "" && !strings.EqualFold(health, "unknown") {
		b.Health = health
	}
	if rate > 0 && full > 0 {
		switch status {
		case "discharging":
			b.TimeLeft = formatBatteryHours(float64(now) / float64(rate))
		case "charging":
			b.TimeLeft = formatBatteryHours(float64(full-now) / float64(rate))
		}
	}
	return b, true
}

// normalizeBatteryStatus maps the kernel's status words onto the lowercase
// vocabulary the Power card understands. "Not charging" on mains power is a
// charge limit being held, which reads as charged.
func normalizeBatteryStatus(raw string, ac bool) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "charging":
		return "charging"
	case "discharging":
		return "discharging"
	case "full":
		return "charged"
	case "not charging":
		if ac {
			return "charged"
		}
		return "not charging"
	}
	if ac {
		return "ac"
	}
	return ""
}

func formatBatteryHours(hours float64) string {
	if hours <= 0 || hours >= 100 || math.IsNaN(hours) || math.IsInf(hours, 0) {
		return ""
	}
	minutes := int(math.Round(hours * 60))
	return fmt.Sprintf("%d:%02d", minutes/60, minutes%60)
}

// readBatteryTemp returns the first machine battery temperature, which the
// kernel reports in tenths of a degree Celsius.
func readBatteryTemp(root string) float64 {
	for _, ps := range listPowerSupplies(root) {
		if (ps.typ != "Battery" && ps.typ != "UPS") || ps.scope == "Device" || ps.notReady {
			continue
		}
		if v, ok := readInt(filepath.Join(ps.dir, "temp")); ok {
			if c := float64(v) / 10; validTempC(c) {
				return c
			}
		}
	}
	return 0
}

// machineBattery reports a supply that powers this computer: a Battery or UPS
// with system scope that is present.
func machineBattery(ps powerSupply) bool {
	return (ps.typ == "Battery" || ps.typ == "UPS") && ps.scope != "Device" && !ps.notReady
}

// supplyWatts reads a supply's instantaneous power in watts: power_now (uW),
// else current_now (uA) times voltage_now (uV). Drivers differ on the sign,
// so the magnitude is returned and the caller applies the direction.
func supplyWatts(dir string) (float64, bool) {
	if uw, ok := readInt(filepath.Join(dir, "power_now")); ok && uw != 0 {
		return math.Abs(float64(uw)) / 1e6, true
	}
	ua, okA := readInt(filepath.Join(dir, "current_now"))
	uv, okV := readInt(filepath.Join(dir, "voltage_now"))
	if okA && okV && ua != 0 && uv > 0 {
		return math.Abs(float64(ua)) * float64(uv) / 1e12, true
	}
	return 0, false
}

// readPower fills the power fields of ThermalStatus the way the Mac reads
// them from AppleSmartBattery: BatteryPower is positive while discharging and
// negative while charging; SystemPower is what the machine draws, known only
// while the battery alone supplies it; AdapterPower is the rated maximum of an
// online charger (USB-PD and UCSI ports publish voltage_max and current_max;
// a plain AC supply does not, and the Input line stays hidden).
func readPower(root string, thermal *ThermalStatus) {
	supplies := listPowerSupplies(root)
	ac := acOnline(supplies)
	var battery float64
	for _, ps := range supplies {
		if !machineBattery(ps) {
			continue
		}
		watts, ok := supplyWatts(ps.dir)
		if !ok || watts >= 500 {
			continue
		}
		switch normalizeBatteryStatus(readTrimmed(filepath.Join(ps.dir, "status")), ac) {
		case "discharging":
			battery += watts
		case "charging":
			battery -= watts
		}
	}
	thermal.BatteryPower = battery
	if battery > 0 && !ac {
		thermal.SystemPower = battery
	}
	for _, ps := range supplies {
		if ps.typ == "Battery" || ps.typ == "UPS" || ps.scope == "Device" || !ps.hasOnl || !ps.online {
			continue
		}
		uv, okV := readInt(filepath.Join(ps.dir, "voltage_max"))
		ua, okA := readInt(filepath.Join(ps.dir, "current_max"))
		if okV && okA && uv > 0 && ua > 0 {
			if w := float64(uv) * float64(ua) / 1e12; w < 500 {
				thermal.AdapterPower = max(thermal.AdapterPower, math.Round(w))
			}
		}
	}
}

// PeripheralBattery is a device's own battery reported through power_supply
// with scope=Device: a wireless mouse, keyboard, headset or stylus.
type PeripheralBattery struct {
	Name    string  `json:"name"`
	Percent float64 `json:"percent"` // -1 when the device reports only a level
	Level   string  `json:"level,omitempty"`
	Status  string  `json:"status,omitempty"`
}

func collectPeripherals() []PeripheralBattery {
	return readPeripherals("/")
}

// readPeripherals lists scope=Device batteries, named by model_name (with the
// manufacturer when the model does not already carry it), else by the
// supply's directory name.
func readPeripherals(root string) []PeripheralBattery {
	var out []PeripheralBattery
	for _, ps := range listPowerSupplies(root) {
		if ps.scope != "Device" || ps.notReady || (ps.typ != "Battery" && ps.typ != "") {
			continue
		}
		p := PeripheralBattery{Percent: -1}
		if v, ok := readInt(filepath.Join(ps.dir, "capacity")); ok && v >= 0 && v <= 100 {
			p.Percent = float64(v)
		}
		if level := readTrimmed(filepath.Join(ps.dir, "capacity_level")); level != "" && !strings.EqualFold(level, "unknown") {
			p.Level = level
		}
		if p.Percent < 0 && p.Level == "" {
			continue
		}
		p.Status = normalizeBatteryStatus(readTrimmed(filepath.Join(ps.dir, "status")), false)
		model := readTrimmed(filepath.Join(ps.dir, "model_name"))
		vendor := readTrimmed(filepath.Join(ps.dir, "manufacturer"))
		switch {
		case model != "" && vendor != "" && !strings.Contains(strings.ToLower(model), strings.ToLower(vendor)):
			p.Name = vendor + " " + model
		case model != "":
			p.Name = model
		default:
			p.Name = filepath.Base(ps.dir)
		}
		out = append(out, p)
	}
	return out
}
