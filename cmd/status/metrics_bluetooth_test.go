package main

import (
	"slices"
	"testing"
)

func TestParseSPBluetoothReadsConnectionStateFromGroupHeaders(t *testing.T) {
	// system_profiler SPBluetoothDataType lists devices under "Connected:" and
	// "Not Connected:" group headers and gives them no "Connected: Yes" line of
	// their own. Reading the headers as an attribute left every device
	// disconnected (#1967).
	raw := `Bluetooth:

      Bluetooth Controller:
          Address: 00:11:22:33:44:55
          State: On
          Discoverable: Off
          Supported services: 0x392039 < HFP AVRCP A2DP >
          Transport: PCIe
      Connected:
          Desk Mouse:
              Address: AA:BB:CC:00:00:01
              Minor Type: Mouse
              Services: 0x400000 < BLE >
          Desk Keyboard:
              Address: AA:BB:CC:00:00:02
              Minor Type: Keyboard
      Not Connected:
          Studio Buds:
              Address: AA:BB:CC:00:00:03
              Minor Type: Headphones
          Car Stereo:
              Address: AA:BB:CC:00:00:04
              Minor Type: Headset
`
	want := []BluetoothDevice{
		{Name: "Desk Mouse", Connected: true},
		{Name: "Desk Keyboard", Connected: true},
		{Name: "Studio Buds", Connected: false},
		{Name: "Car Stereo", Connected: false},
	}
	if got := parseSPBluetooth(raw); !slices.Equal(got, want) {
		t.Fatalf("expected %+v, got %+v", want, got)
	}
}

func TestParseSPBluetoothKeepsPerDeviceConnectedLine(t *testing.T) {
	// A device that carries its own Connected line keeps that answer when its
	// group header says nothing about the state.
	raw := `Bluetooth:

      Devices:
          Desk Mouse:
              Address: AA:BB:CC:00:00:01
              Connected: Yes
              Battery Level: 60%
          Studio Buds:
              Address: AA:BB:CC:00:00:03
              Connected: No
`
	want := []BluetoothDevice{
		{Name: "Desk Mouse", Connected: true, Battery: "60%"},
		{Name: "Studio Buds", Connected: false},
	}
	if got := parseSPBluetooth(raw); !slices.Equal(got, want) {
		t.Fatalf("expected %+v, got %+v", want, got)
	}
}
