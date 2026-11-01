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
// machine, and are skipped.
func readBatteries(root string) []BatteryStatus {
	supplies := listPowerSupplies(root)
	ac := acOnline(supplies)

	var out []BatteryStatus
	for _, ps := range supplies {
		if (ps.typ != "Battery" && ps.typ != "UPS") || ps.scope == "Device" || ps.notReady {
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
