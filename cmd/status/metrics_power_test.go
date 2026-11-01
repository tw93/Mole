package main

import (
	"strings"
	"testing"
)

func TestReadPowerDischargingFromPowerNow(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/power_supply/BAT0/type":      "Battery\n",
		"sys/class/power_supply/BAT0/status":    "Discharging\n",
		"sys/class/power_supply/BAT0/capacity":  "60\n",
		"sys/class/power_supply/BAT0/power_now": "12500000\n",
		"sys/class/power_supply/AC/type":        "Mains\n",
		"sys/class/power_supply/AC/online":      "0\n",
	})
	var th ThermalStatus
	readPower(root, &th)
	if th.BatteryPower != 12.5 || th.SystemPower != 12.5 || th.AdapterPower != 0 {
		t.Fatalf("power = %+v, want 12.5 W battery and system, no adapter", th)
	}
}

func TestReadPowerChargingFromCurrentAndVoltageWithUSBPDAdapter(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/power_supply/BAT1/type":        "Battery\n",
		"sys/class/power_supply/BAT1/status":      "Charging\n",
		"sys/class/power_supply/BAT1/capacity":    "40\n",
		"sys/class/power_supply/BAT1/current_now": "-2000000\n", // some drivers sign it
		"sys/class/power_supply/BAT1/voltage_now": "15000000\n",
		// A UCSI USB-C port with a 65 W PD charger; the plain AC supply
		// publishes no rating.
		"sys/class/power_supply/ucsi-source-psy-USBC000:001/type":        "USB\n",
		"sys/class/power_supply/ucsi-source-psy-USBC000:001/online":      "1\n",
		"sys/class/power_supply/ucsi-source-psy-USBC000:001/voltage_max": "20000000\n",
		"sys/class/power_supply/ucsi-source-psy-USBC000:001/current_max": "3250000\n",
		"sys/class/power_supply/AC/type":                                 "Mains\n",
		"sys/class/power_supply/AC/online":                               "1\n",
		// A mouse's own battery never counts toward the machine's power.
		"sys/class/power_supply/hidpp_battery_0/type":      "Battery\n",
		"sys/class/power_supply/hidpp_battery_0/scope":     "Device\n",
		"sys/class/power_supply/hidpp_battery_0/status":    "Discharging\n",
		"sys/class/power_supply/hidpp_battery_0/power_now": "1000000\n",
	})
	var th ThermalStatus
	readPower(root, &th)
	if th.BatteryPower != -30 {
		t.Fatalf("battery power = %v, want -30 (charging at 2 A x 15 V)", th.BatteryPower)
	}
	if th.SystemPower != 0 {
		t.Fatalf("system power = %v, want 0: on AC the draw is not measured", th.SystemPower)
	}
	if th.AdapterPower != 65 {
		t.Fatalf("adapter power = %v, want 65 W from voltage_max x current_max", th.AdapterPower)
	}
	card := renderBatteryCard(readBatteries(root), th, true)
	if !strings.Contains(strings.Join(card.lines, "\n"), "65W max") {
		t.Fatalf("Input line missing: %q", card.lines)
	}
}

func TestReadPeripheralsListsDeviceScopeBatteries(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/power_supply/hidpp_battery_0/type":                 "Battery\n",
		"sys/class/power_supply/hidpp_battery_0/scope":                "Device\n",
		"sys/class/power_supply/hidpp_battery_0/capacity":             "15\n",
		"sys/class/power_supply/hidpp_battery_0/status":               "Discharging\n",
		"sys/class/power_supply/hidpp_battery_0/model_name":           "MX Master 3\n",
		"sys/class/power_supply/hidpp_battery_0/manufacturer":         "Logitech\n",
		"sys/class/power_supply/ps-controller-battery/type":           "Battery\n",
		"sys/class/power_supply/ps-controller-battery/scope":          "Device\n",
		"sys/class/power_supply/ps-controller-battery/capacity_level": "Normal\n",
		"sys/class/power_supply/BAT0/type":                            "Battery\n",
		"sys/class/power_supply/BAT0/capacity":                        "80\n",
	})
	got := readPeripherals(root)
	if len(got) != 2 {
		t.Fatalf("peripherals = %+v, want the mouse and the controller only", got)
	}
	if got[0].Name != "Logitech MX Master 3" || got[0].Percent != 15 || got[0].Status != "discharging" {
		t.Fatalf("mouse = %+v", got[0])
	}
	if got[1].Name != "ps-controller-battery" || got[1].Percent != -1 || got[1].Level != "Normal" {
		t.Fatalf("controller = %+v", got[1])
	}
	if len(readBatteries(root)) != 1 {
		t.Fatal("the machine battery list must stay without peripherals")
	}

	// A desktop with no battery still gets a Power card for its peripherals.
	cards := buildCards(MetricsSnapshot{Peripherals: got}, 80, 0, true)
	power := findCard(t, cards, "Power")
	text := strings.Join(power.lines, "\n")
	if !strings.Contains(text, "Logitech MX Master 3  ") || !strings.Contains(text, "15%") || !strings.Contains(text, "Normal") {
		t.Fatalf("power card = %q", power.lines)
	}
}

func TestReadZramTotalsDevices(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/block/zram0/mm_stat": "2000000000 600000000 640000000 0 700000000 1234 0 0 0\n",
		"sys/block/zram1/mm_stat": "1000000000 300000000 360000000 0 400000000 0 0 0 0\n",
		"sys/block/zram2/mm_stat": "garbage\n",
	})
	z := readZram(root)
	if z == nil || z.Devices != 2 || z.Original != 3e9 || z.Compressed != 9e8 || z.MemUsed != 1e9 || z.Ratio != 3 {
		t.Fatalf("zram = %+v", z)
	}
	if readZram(writeTree(t, map[string]string{"sys/block/zram0/mm_stat": "0 0 0 0 0 0 0 0 0\n"})) != nil {
		t.Fatal("an empty zram device must not be reported")
	}
	card := renderMemoryCard(MemoryStatus{Total: 16e9, Used: 8e9, Available: 8e9, SwapTotal: 8e9, SwapUsed: 3e9, Zram: z}, 0)
	if !strings.Contains(strings.Join(card.lines, "\n"), "Zram   ") || !strings.Contains(strings.Join(card.lines, "\n"), "3.0x") {
		t.Fatalf("memory card = %q", card.lines)
	}
}

func TestReadCPUFrequencyAndHybridCores(t *testing.T) {
	files := map[string]string{
		"sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq": "4000000\n",
		"sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq": "2000000\n",
		"sys/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq": "1200000\n",
		"sys/devices/system/cpu/cpu3/cpufreq/scaling_cur_freq": "800000\n",
		// 2 P-cores with Hyper-Threading (cpu0-3) and 4 E-cores (cpu4-7).
		"sys/devices/cpu_core/cpus": "0-3\n",
		"sys/devices/cpu_atom/cpus": "4-7\n",
	}
	for cpu, core := range map[string]string{"0": "0", "1": "0", "2": "4", "3": "4", "4": "8", "5": "9", "6": "10", "7": "11"} {
		files["sys/devices/system/cpu/cpu"+cpu+"/topology/core_id"] = core + "\n"
		files["sys/devices/system/cpu/cpu"+cpu+"/topology/physical_package_id"] = "0\n"
	}
	root := writeTree(t, files)
	avg, peak := readCPUFrequency(root)
	if avg != 2000 || peak != 4000 {
		t.Fatalf("freq = %v avg / %v max, want 2000 / 4000", avg, peak)
	}
	p, e := readHybridCores(root)
	if p != 2 || e != 4 {
		t.Fatalf("cores = %dP+%dE, want 2P+4E", p, e)
	}
	if p, e := readHybridCores(writeTree(t, map[string]string{"sys/devices/cpu/cpus": "0-7\n"})); p != 0 || e != 0 {
		t.Fatalf("non-hybrid = %dP+%dE, want 0+0", p, e)
	}
	if got := parseCPUList("0-2,5,7-8"); len(got) != 6 || got[3] != 5 {
		t.Fatalf("parseCPUList = %v", got)
	}

	card := renderCPUCard(CPUStatus{LogicalCPU: 8, PCoreCount: 2, ECoreCount: 4, FreqAvgMHz: avg, FreqMaxMHz: peak}, ThermalStatus{}, 0)
	text := strings.Join(card.lines, "\n")
	if !strings.Contains(text, "2P+4E") || !strings.Contains(text, "Freq   2.0 GHz avg · 4.0 GHz max") {
		t.Fatalf("cpu card = %q", card.lines)
	}
}
