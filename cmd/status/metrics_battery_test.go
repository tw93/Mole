package main

import (
	"testing"
)

func TestReadBatteriesThinkPadDischarging(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/power_supply/BAT0/type":               "Battery\n",
		"sys/class/power_supply/BAT0/status":             "Discharging\n",
		"sys/class/power_supply/BAT0/capacity":           "63\n",
		"sys/class/power_supply/BAT0/energy_now":         "30000000\n",
		"sys/class/power_supply/BAT0/energy_full":        "45000000\n",
		"sys/class/power_supply/BAT0/energy_full_design": "50000000\n",
		"sys/class/power_supply/BAT0/power_now":          "10000000\n",
		"sys/class/power_supply/BAT0/cycle_count":        "212\n",
		"sys/class/power_supply/BAT0/temp":               "312\n",
		"sys/class/power_supply/AC/type":                 "Mains\n",
		"sys/class/power_supply/AC/online":               "0\n",
	})
	got := readBatteries(root)
	if len(got) != 1 {
		t.Fatalf("readBatteries() = %#v, want one battery", got)
	}
	b := got[0]
	if b.Percent != 63 || b.Status != "discharging" {
		t.Fatalf("percent/status = %v/%q", b.Percent, b.Status)
	}
	if b.Capacity != 90 {
		t.Fatalf("health capacity = %d, want 90 (45/50 Wh)", b.Capacity)
	}
	if b.CycleCount != 212 {
		t.Fatalf("cycle count = %d, want 212", b.CycleCount)
	}
	if b.TimeLeft != "3:00" {
		t.Fatalf("time left = %q, want 3:00 (30 Wh at 10 W)", b.TimeLeft)
	}
	if temp := readBatteryTemp(root); temp != 31.2 {
		t.Fatalf("battery temp = %v, want 31.2", temp)
	}
}

func TestReadBatteriesFallsBackToChargeFilesAndComputesPercent(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/power_supply/BAT1/type":               "Battery\n",
		"sys/class/power_supply/BAT1/status":             "Charging\n",
		"sys/class/power_supply/BAT1/charge_now":         "2000000\n",
		"sys/class/power_supply/BAT1/charge_full":        "4000000\n",
		"sys/class/power_supply/BAT1/charge_full_design": "5000000\n",
		"sys/class/power_supply/BAT1/current_now":        "2000000\n",
		"sys/class/power_supply/ADP1/type":               "Mains\n",
		"sys/class/power_supply/ADP1/online":             "1\n",
	})
	got := readBatteries(root)
	if len(got) != 1 {
		t.Fatalf("readBatteries() = %#v", got)
	}
	b := got[0]
	if b.Percent != 50 || b.Status != "charging" || b.Capacity != 80 {
		t.Fatalf("battery = %#v, want 50%% charging, health 80", b)
	}
	if b.TimeLeft != "1:00" {
		t.Fatalf("time to full = %q, want 1:00", b.TimeLeft)
	}
	if b.CycleCount != 0 {
		t.Fatalf("cycle count = %d without cycle_count file, want 0", b.CycleCount)
	}
}

func TestReadBatteriesSkipsPeripheralsEmptyBaysAndAC(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/power_supply/hidpp_battery_0/type":     "Battery\n",
		"sys/class/power_supply/hidpp_battery_0/scope":    "Device\n",
		"sys/class/power_supply/hidpp_battery_0/capacity": "80\n",
		"sys/class/power_supply/BAT0/type":                "Battery\n",
		"sys/class/power_supply/BAT0/present":             "0\n",
		"sys/class/power_supply/BAT0/capacity":            "50\n",
		"sys/class/power_supply/AC/type":                  "Mains\n",
		"sys/class/power_supply/AC/online":                "1\n",
	})
	if got := readBatteries(root); len(got) != 0 {
		t.Fatalf("readBatteries() = %#v, want none", got)
	}
}

func TestReadBatteriesNoPowerSupplyDirectory(t *testing.T) {
	if got := readBatteries(t.TempDir()); len(got) != 0 {
		t.Fatalf("readBatteries() on a machine without power_supply = %#v", got)
	}
}

func TestNormalizeBatteryStatus(t *testing.T) {
	tests := []struct {
		raw  string
		ac   bool
		want string
	}{
		{"Charging", true, "charging"},
		{"Discharging", false, "discharging"},
		{"Full", true, "charged"},
		{"Not charging", true, "charged"},
		{"Not charging", false, "not charging"},
		{"Unknown", true, "ac"},
		{"", false, ""},
	}
	for _, tt := range tests {
		if got := normalizeBatteryStatus(tt.raw, tt.ac); got != tt.want {
			t.Fatalf("normalizeBatteryStatus(%q, %v) = %q, want %q", tt.raw, tt.ac, got, tt.want)
		}
	}
}

func TestFormatBatteryHoursRejectsNonsense(t *testing.T) {
	for _, h := range []float64{0, -1, 150} {
		if got := formatBatteryHours(h); got != "" {
			t.Fatalf("formatBatteryHours(%v) = %q, want empty", h, got)
		}
	}
	if got := formatBatteryHours(1.5); got != "1:30" {
		t.Fatalf("formatBatteryHours(1.5) = %q", got)
	}
}

func TestBatteryCardHiddenWithoutBatteryOnceProbed(t *testing.T) {
	titles := func(cards []cardData) []string {
		var out []string
		for _, c := range cards {
			out = append(out, c.title)
		}
		return out
	}
	has := func(cards []cardData, title string) bool {
		for _, c := range cards {
			if c.title == title {
				return true
			}
		}
		return false
	}
	probed := buildCards(MetricsSnapshot{}, 40, 0, true)
	if has(probed, "Power") {
		t.Fatalf("cards %v include Power for a machine without a battery", titles(probed))
	}
	unprobed := buildCards(MetricsSnapshot{}, 40, 0, false)
	if !has(unprobed, "Power") {
		t.Fatalf("cards %v dropped the placeholder before the first full collection", titles(unprobed))
	}
	withBattery := buildCards(MetricsSnapshot{Batteries: []BatteryStatus{{Percent: 50, Status: "discharging"}}}, 40, 0, true)
	if !has(withBattery, "Power") {
		t.Fatalf("cards %v hide a present battery", titles(withBattery))
	}
}
