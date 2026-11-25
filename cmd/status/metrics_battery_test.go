package main

import (
	"context"
	"errors"
	"math"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestParseSystemPowerJSON(t *testing.T) {
	raw := `{
  "SPPowerDataType" : [
    {
      "sppower_battery_health_info" : {
        "sppower_battery_cycle_count" : 4,
        "sppower_battery_health" : "Good",
        "sppower_battery_health_maximum_capacity" : "100\u00a0%"
      }
    }
  ]
}`

	health, cycles, capacity, ok := parseSystemPowerJSON(raw)

	if !ok {
		t.Fatal("expected battery health JSON to parse")
	}
	if health != "Good" {
		t.Fatalf("health = %q, want Good", health)
	}
	if cycles != 4 {
		t.Fatalf("cycles = %d, want 4", cycles)
	}
	if capacity != 100 {
		t.Fatalf("capacity = %d, want 100", capacity)
	}
}

func TestParseSystemPowerJSONRejectsInvalidPayload(t *testing.T) {
	_, _, _, ok := parseSystemPowerJSON(`{"SPPowerDataType":[{}]}`)
	if ok {
		t.Fatal("expected empty battery health JSON to be ignored")
	}
}

func TestParseSystemPowerText(t *testing.T) {
	nonBreakingSpace := string(rune(0x00a0))
	raw := "    Battery Information:\n\n" +
		"      Health Information:\n" +
		"          Cycle Count: 12\n" +
		"          Condition: Normal\n" +
		"          Maximum Capacity: 97" + nonBreakingSpace + "%\n"

	health, cycles, capacity := parseSystemPowerText(raw)

	if health != "Normal" {
		t.Fatalf("health = %q, want Normal", health)
	}
	if cycles != 12 {
		t.Fatalf("cycles = %d, want 12", cycles)
	}
	if capacity != 97 {
		t.Fatalf("capacity = %d, want 97", capacity)
	}
}

func TestMergeBatteryHealthDataPrefersPublishedCapacity(t *testing.T) {
	health, cycles, capacity := mergeBatteryHealthData("Good", 12, 100, 13, 96)

	if health != "Good" {
		t.Fatalf("health = %q, want Good", health)
	}
	if cycles != 13 {
		t.Fatalf("cycles = %d, want 13", cycles)
	}
	if capacity != 100 {
		t.Fatalf("capacity = %d, want published 100", capacity)
	}
}

func TestMergeBatteryHealthDataFallsBackToAppleSmartBatteryCapacity(t *testing.T) {
	_, cycles, capacity := mergeBatteryHealthData("Good", 12, 0, 13, 96)

	if cycles != 13 {
		t.Fatalf("cycles = %d, want 13", cycles)
	}
	if capacity != 96 {
		t.Fatalf("capacity = %d, want fallback 96", capacity)
	}
}

func TestParseAppleSmartBatteryHealthNeverTreatsMaxCapacityAsHealth(t *testing.T) {
	out := `
  | |   "BatteryData" = {"MaxCapacity"=100,"DesignCapacity"=6075,"BatteryHealthMetric"=0}
  | |   "NominalChargeCapacity" = 6008
  | |   "MaxCapacity" = 100
  | |   "DesignCapacity" = 6075
  | |   "AppleRawMaxCapacity" = 5858
  | |   "CycleCount" = 48
`

	cycles, capacity := parseAppleSmartBatteryHealth(out)

	if cycles != 48 {
		t.Fatalf("cycles = %d, want 48", cycles)
	}
	if capacity != 96 {
		t.Fatalf("capacity = %d, want raw fallback 96", capacity)
	}
}

func TestParseAppleSmartBatteryHealthFallsBackToNominalWhenRawUnavailable(t *testing.T) {
	out := `
  | |   "MaxCapacity" = 7745
  | |   "DesignCapacity" = 8579
  | |   "NominalChargeCapacity" = 7989
  | |   "CycleCount" = 12
`

	cycles, capacity := parseAppleSmartBatteryHealth(out)

	if cycles != 12 {
		t.Fatalf("cycles = %d, want 12", cycles)
	}
	if capacity != 93 {
		t.Fatalf("capacity = %d, want 93", capacity)
	}
}

func TestParseAppleSmartBatteryHealthPrefersRawMaxCapacity(t *testing.T) {
	out := `
  | |   "DesignCapacity" = 10000
  | |   "AppleRawMaxCapacity" = 7800
  | |   "NominalChargeCapacity" = 8300
  | |   "CycleCount" = 250
`

	cycles, capacity := parseAppleSmartBatteryHealth(out)

	if cycles != 250 {
		t.Fatalf("cycles = %d, want 250", cycles)
	}
	if capacity != 78 {
		t.Fatalf("capacity = %d, want 78", capacity)
	}
}

func TestParseAppleSmartBatteryHealthFallsBackToRawMaxCapacity(t *testing.T) {
	out := `
  | |   "DesignCapacity" = 10000
  | |   "AppleRawMaxCapacity" = 7800
  | |   "CycleCount" = 12
`

	cycles, capacity := parseAppleSmartBatteryHealth(out)

	if cycles != 12 {
		t.Fatalf("cycles = %d, want 12", cycles)
	}
	if capacity != 78 {
		t.Fatalf("capacity = %d, want 78", capacity)
	}
}

func TestBatteryHealthPercentRoundsAndClamps(t *testing.T) {
	if got := batteryHealthPercent(10000, 8249, 0); got != 82 {
		t.Errorf("8249/10000 rounded = %d, want 82", got)
	}
	if got := batteryHealthPercent(10000, 8250, 0); got != 83 {
		t.Errorf("8250/10000 rounded = %d, want 83", got)
	}
	if got := batteryHealthPercent(10000, 12000, 0); got != 100 {
		t.Errorf("12000/10000 clamped = %d, want 100", got)
	}
	if got := batteryHealthPercent(0, 8000, 0); got != 0 {
		t.Errorf("zero design = %d, want 0", got)
	}
	if got := batteryHealthPercent(10000, 0, 0); got != 0 {
		t.Errorf("no capacity = %d, want 0", got)
	}
}

func TestParseAppleSmartBatteryThermalKeepsBatteryTemperatureOutOfCPUTemp(t *testing.T) {
	out := `
  | |   "Temperature" = 3055
  | |   "SystemPowerIn" = 19967
  | |   "BatteryPower" = 13654
  | |   "AdapterDetails" = {"Watts" = 96}
`

	thermal := parseAppleSmartBatteryThermal(out)

	if thermal.CPUTemp != 0 {
		t.Fatalf("expected cpu temp to stay unset, got %v", thermal.CPUTemp)
	}
	if math.Abs(thermal.BatteryTemp-30.55) > 0.001 {
		t.Fatalf("expected battery temp 30.55, got %v", thermal.BatteryTemp)
	}
	if math.Abs(thermal.SystemPower-19.967) > 0.001 {
		t.Fatalf("expected system power 19.967W, got %v", thermal.SystemPower)
	}
	if thermal.AdapterPower != 96 {
		t.Fatalf("expected adapter power 96W, got %v", thermal.AdapterPower)
	}
	if math.Abs(thermal.BatteryPower-13.654) > 0.001 {
		t.Fatalf("expected battery power 13.654W, got %v", thermal.BatteryPower)
	}
}

func TestParseAppleSmartBatteryThermalParsesTwosComplementBatteryPower(t *testing.T) {
	out := `
  | |   "BatteryPower"=18446744073709539271
`

	thermal := parseAppleSmartBatteryThermal(out)

	if math.Abs(thermal.BatteryPower-(-12.345)) > 0.001 {
		t.Fatalf("expected battery power -12.345W, got %v", thermal.BatteryPower)
	}
}

func TestParseAppleSmartBatteryThermalDerivesBatteryWattsFromVoltageAndAmperage(t *testing.T) {
	out := `
  | |   "Voltage" = 12000
  | |   "InstantAmperage" = -1500
`

	thermal := parseAppleSmartBatteryThermal(out)

	if math.Abs(thermal.BatteryPower-18.0) > 0.001 {
		t.Fatalf("expected derived battery power 18W, got %v", thermal.BatteryPower)
	}
}

// Mac Studio (Mac17,15, macOS 27.2.1) has no battery and its telemetry reports
// SystemPowerIn = 0 while the DC input voltage and current are live.
func TestParseAppleSmartBatteryThermalDerivesSystemPowerFromInputWhenSystemPowerInIsZero(t *testing.T) {
	out := `
      "BatteryInstalled" = No
      "AdapterDetails" = {"FamilyCode"=0}
      "PowerTelemetryData" = {"SystemPowerInAccumulatorCount"=0,"SystemLoad"=0,"SystemCurrentIn"=1468,"SystemVoltageIn"=12050,"SystemPowerIn"=0,"BatteryPower"=0}
      "Voltage" = 0
      "Amperage" = 0
`

	thermal := parseAppleSmartBatteryThermal(out)

	if math.Abs(thermal.SystemPower-17.6894) > 0.001 {
		t.Fatalf("expected system power 17.689W from 12050mV x 1468mA, got %v", thermal.SystemPower)
	}
	if thermal.BatteryPower != 0 {
		t.Fatalf("expected no battery power without a battery, got %v", thermal.BatteryPower)
	}
}

func TestParseAppleSmartBatteryThermalPrefersReportedSystemPowerIn(t *testing.T) {
	out := `
      "PowerTelemetryData" = {"SystemCurrentIn"=1000,"SystemVoltageIn"=20000,"SystemPowerIn"=19967}
`

	thermal := parseAppleSmartBatteryThermal(out)

	if math.Abs(thermal.SystemPower-19.967) > 0.001 {
		t.Fatalf("expected reported system power 19.967W, got %v", thermal.SystemPower)
	}
}

func TestParseAppleSmartBatteryThermalLeavesSystemPowerUnsetWithoutInputCurrent(t *testing.T) {
	out := `
      "PowerTelemetryData" = {"SystemCurrentIn"=0,"SystemVoltageIn"=12050,"SystemPowerIn"=0}
`

	thermal := parseAppleSmartBatteryThermal(out)

	if thermal.SystemPower != 0 {
		t.Fatalf("expected system power to stay unset, got %v", thermal.SystemPower)
	}
}

func TestParseAppleSmartBatteryThermalIgnoresRawAdapterWatts(t *testing.T) {
	out := `
  | |   "AppleRawAdapterDetails" = {"Watts" = 140}
  | |   "AdapterDetails" = {"Watts" = 96}
`

	thermal := parseAppleSmartBatteryThermal(out)

	if thermal.AdapterPower != 96 {
		t.Fatalf("expected normalized adapter power 96W, got %v", thermal.AdapterPower)
	}
}

func TestCollectBatteriesEnforcesTimeoutOnPMSet(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("pmset collection is darwin-only")
	}

	origRunCmd, origCommandExists := runCmd, commandExists
	t.Cleanup(func() {
		runCmd, commandExists = origRunCmd, origCommandExists
	})

	commandExists = func(name string) bool {
		return name == "pmset"
	}

	var observedDeadline time.Time
	runCmd = func(ctx context.Context, name string, _ ...string) (string, error) {
		if name == "pmset" {
			if dl, ok := ctx.Deadline(); ok {
				observedDeadline = dl
			}
			return "-InternalBattery-0 (id=1234567)\t85%; discharging; 4:30 remaining present: true\n", nil
		}
		return "", errors.New("command not mocked")
	}

	batts, err := collectBatteries()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(batts) == 0 {
		t.Fatal("expected battery status to be collected")
	}
	if observedDeadline.IsZero() {
		t.Fatal("expected pmset runCmd context to have a deadline")
	}
	remaining := time.Until(observedDeadline)
	if remaining <= 0 || remaining > time.Second {
		t.Fatalf("expected deadline <= 1s in the future, got %v", remaining)
	}
}

// macOS 27 moved the battery's gauge data under the AppleSmartBatteryPack child,
// so the top-level AppleSmartBattery read has no Temperature key at all and the
// card showed 0 C. The fixture mirrors that pack output; the lifetime block
// comes first so a loose key match on MaximumTemperature would win.
const batteryPackOutput = `
  | |   "BatteryData" = {"LifetimeData"={"MaximumTemperature"=44,"AverageTemperature"=271,"MinimumTemperature"=13},"CycleCount"=66,"DesignCapacity"=8579,"Temperature"=3200,"VirtualTemperature"=3100,"Voltage"=12964}
`

func TestCollectThermalReadsBatteryPackWhenTopLevelHasNoTemperature(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("battery thermal collection is darwin-only")
	}
	origRunCmd := runCmd
	t.Cleanup(func() { runCmd = origRunCmd })

	runCmd = func(_ context.Context, name string, args ...string) (string, error) {
		switch {
		case name == "ioreg" && strings.Join(args, " ") == "-rn AppleSmartBattery":
			return "  | |   \"SystemPowerIn\" = 19967\n", nil
		case name == "ioreg" && strings.Join(args, " ") == "-rc AppleSmartBatteryPack -l":
			return batteryPackOutput, nil
		}
		return "", errors.New("command not mocked")
	}

	thermal := collectThermal()

	if math.Abs(thermal.BatteryTemp-32.0) > 0.001 {
		t.Fatalf("expected battery temp 32 from the pack, got %v", thermal.BatteryTemp)
	}
	if math.Abs(thermal.SystemPower-19.967) > 0.001 {
		t.Fatalf("top-level power must still be read, got %v", thermal.SystemPower)
	}
}

func TestCollectThermalSkipsBatteryPackWhenTopLevelHasTemperature(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("battery thermal collection is darwin-only")
	}
	origRunCmd := runCmd
	t.Cleanup(func() { runCmd = origRunCmd })

	packRead := false
	runCmd = func(_ context.Context, name string, args ...string) (string, error) {
		if name == "ioreg" && strings.Join(args, " ") == "-rc AppleSmartBatteryPack -l" {
			packRead = true
			return batteryPackOutput, nil
		}
		if name == "ioreg" {
			return "  | |   \"Temperature\" = 3055\n", nil
		}
		return "", errors.New("command not mocked")
	}

	thermal := collectThermal()

	if packRead {
		t.Fatal("the pack read is a fallback and must not run when the top level has a temperature")
	}
	if math.Abs(thermal.BatteryTemp-30.55) > 0.001 {
		t.Fatalf("expected the top-level 30.55, got %v", thermal.BatteryTemp)
	}
}
