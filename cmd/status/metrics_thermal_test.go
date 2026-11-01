package main

import (
	"testing"
)

func TestReadThermalIntelCoretempAndAmdgpu(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/hwmon/hwmon2/name":         "coretemp\n",
		"sys/class/hwmon/hwmon2/temp1_input":  "52000\n",
		"sys/class/hwmon/hwmon2/temp1_label":  "Package id 0\n",
		"sys/class/hwmon/hwmon2/temp2_input":  "49000\n",
		"sys/class/hwmon/hwmon2/temp2_label":  "Core 0\n",
		"sys/class/hwmon/hwmon3/name":         "amdgpu\n",
		"sys/class/hwmon/hwmon3/temp1_input":  "61000\n",
		"sys/class/hwmon/hwmon3/temp1_label":  "edge\n",
		"sys/class/hwmon/hwmon3/temp2_input":  "70000\n",
		"sys/class/hwmon/hwmon3/temp2_label":  "junction\n",
		"sys/class/hwmon/hwmon4/name":         "nvme\n",
		"sys/class/hwmon/hwmon4/temp1_input":  "99000\n",
		"sys/class/hwmon/hwmon5/name":         "thinkpad\n",
		"sys/class/hwmon/hwmon5/fan1_input":   "3100\n",
		"sys/class/hwmon/hwmon5/fan2_input":   "0\n",
		"sys/class/power_supply/BAT0/type":    "Battery\n",
		"sys/class/power_supply/BAT0/temp":    "305\n",
		"sys/class/power_supply/BAT0/present": "1\n",
	})
	th := readThermal(root)
	if th.CPUTemp != 52 {
		t.Fatalf("CPUTemp = %v, want 52 (Package id 0, not Core 0 or nvme)", th.CPUTemp)
	}
	if th.GPUTemp != 61 {
		t.Fatalf("GPUTemp = %v, want 61 (edge)", th.GPUTemp)
	}
	if th.BatteryTemp != 30.5 {
		t.Fatalf("BatteryTemp = %v, want 30.5", th.BatteryTemp)
	}
	if th.FanSpeed != 3100 || th.FanCount != 1 {
		t.Fatalf("fan = %d RPM x%d, want 3100 x1 (stopped fan is not counted)", th.FanSpeed, th.FanCount)
	}
}

func TestReadThermalAMDK10tempPrefersTdieOverTctl(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/hwmon/hwmon1/name":        "k10temp\n",
		"sys/class/hwmon/hwmon1/temp1_input": "75000\n",
		"sys/class/hwmon/hwmon1/temp1_label": "Tctl\n",
		"sys/class/hwmon/hwmon1/temp2_input": "65000\n",
		"sys/class/hwmon/hwmon1/temp2_label": "Tdie\n",
	})
	if got := readThermal(root).CPUTemp; got != 65 {
		t.Fatalf("CPUTemp = %v, want 65 (Tdie)", got)
	}
}

func TestReadThermalDriverPriorityAndUnlabelledFallback(t *testing.T) {
	root := writeTree(t, map[string]string{
		// cpu_thermal (ARM) with no label: the hottest channel wins.
		"sys/class/hwmon/hwmon0/name":        "cpu_thermal\n",
		"sys/class/hwmon/hwmon0/temp1_input": "44000\n",
		// zenpower loses to coretemp when both exist.
		"sys/class/hwmon/hwmon1/name":        "zenpower\n",
		"sys/class/hwmon/hwmon1/temp1_input": "90000\n",
		"sys/class/hwmon/hwmon2/name":        "coretemp\n",
		"sys/class/hwmon/hwmon2/temp1_input": "41000\n",
	})
	if got := readThermal(root).CPUTemp; got != 41 {
		t.Fatalf("CPUTemp = %v, want 41 from the higher-priority coretemp", got)
	}
}

func TestReadThermalRejectsInsaneValues(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/hwmon/hwmon0/name":        "coretemp\n",
		"sys/class/hwmon/hwmon0/temp1_input": "0\n",
		"sys/class/hwmon/hwmon0/temp2_input": "-128000\n",
		"sys/class/hwmon/hwmon0/temp3_input": "255000\n",
		"sys/class/hwmon/hwmon0/temp4_input": "125000\n",
	})
	th := readThermal(root)
	if th.CPUTemp != 125 {
		t.Fatalf("CPUTemp = %v, want only the 125 C boundary reading to survive", th.CPUTemp)
	}
	if got := readSensors(root); len(got) != 1 {
		t.Fatalf("readSensors() = %#v, want a single sane reading", got)
	}
}

func TestReadThermalFallsBackToThermalZone(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/thermal/thermal_zone0/type": "acpitz\n",
		"sys/class/thermal/thermal_zone0/temp": "30000\n",
		"sys/class/thermal/thermal_zone1/type": "x86_pkg_temp\n",
		"sys/class/thermal/thermal_zone1/temp": "47000\n",
	})
	if got := readThermal(root).CPUTemp; got != 47 {
		t.Fatalf("CPUTemp = %v, want 47 from x86_pkg_temp, not acpitz", got)
	}
}

func TestReadThermalEmptySysfsIsZero(t *testing.T) {
	th := readThermal(t.TempDir())
	if th != (ThermalStatus{}) {
		t.Fatalf("readThermal() on a VM with no sensors = %#v, want zero value", th)
	}
}

func TestReadThermalUsesDeviceSubdirectoryOnOlderDrivers(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/hwmon/hwmon0/name":               "coretemp\n",
		"sys/class/hwmon/hwmon0/device/temp1_input": "58000\n",
		"sys/class/hwmon/hwmon0/device/temp1_label": "Package id 0\n",
	})
	if got := readThermal(root).CPUTemp; got != 58 {
		t.Fatalf("CPUTemp = %v, want 58", got)
	}
}

func TestReadSensorsListsTempsAndFans(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/hwmon/hwmon0/name":        "thinkpad\n",
		"sys/class/hwmon/hwmon0/temp1_input": "40000\n",
		"sys/class/hwmon/hwmon0/fan1_input":  "2500\n",
	})
	got := readSensors(root)
	if len(got) != 2 {
		t.Fatalf("readSensors() = %#v", got)
	}
	if got[0].Label != "temp1" || got[0].Unit != "°C" || got[0].Note != "thinkpad" || got[0].Value != 40 {
		t.Fatalf("temp sensor = %#v", got[0])
	}
	if got[1].Label != "fan1" || got[1].Unit != "RPM" || got[1].Value != 2500 {
		t.Fatalf("fan sensor = %#v", got[1])
	}
}

func TestHwmonOrdersByNumberNotText(t *testing.T) {
	root := writeTree(t, map[string]string{
		"sys/class/hwmon/hwmon10/name":        "coretemp\n",
		"sys/class/hwmon/hwmon10/temp1_input": "80000\n",
		"sys/class/hwmon/hwmon9/name":         "coretemp\n",
		"sys/class/hwmon/hwmon9/temp1_input":  "40000\n",
	})
	devs := readHwmon(root)
	if len(devs) != 2 || devs[0].temps[0].value != 40 {
		t.Fatalf("readHwmon() order = %#v, want hwmon9 before hwmon10", devs)
	}
}
