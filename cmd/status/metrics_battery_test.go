package main

import (
	"math"
	"testing"
)

func TestParseAppleSmartBatteryThermalKeepsBatteryTemperatureOutOfCPUTemp(t *testing.T) {
	out := `
  | |   "Temperature" = 3055
  | |   "SystemPowerIn"=19967
  | |   "BatteryPower"=13654
  | |   "AdapterDetails" = {"Watts"=96}
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
