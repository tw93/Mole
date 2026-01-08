package main

import (
	"context"
	"errors"
	"runtime"
	"strings"
	"time"
)

const (
	bluetoothCacheTTL   = 30 * time.Second
	bluetoothctlTimeout = 1500 * time.Millisecond
)

func (c *Collector) collectBluetooth(now time.Time) []BluetoothDevice {
	if len(c.lastBT) > 0 && !c.lastBTAt.IsZero() && now.Sub(c.lastBTAt) < bluetoothCacheTTL {
		return c.lastBT
	}

	if devs, err := readSystemProfilerBluetooth(); err == nil && len(devs) > 0 {
		c.lastBTAt = now
		c.lastBT = devs
		return devs
	}

	if devs, err := readBluetoothCTLDevices(); err == nil && len(devs) > 0 {
		c.lastBTAt = now
		c.lastBT = devs
		return devs
	}

	c.lastBTAt = now
	if len(c.lastBT) == 0 {
		c.lastBT = []BluetoothDevice{{Name: "No Bluetooth info", Connected: false}}
	}
	return c.lastBT
}

func readSystemProfilerBluetooth() ([]BluetoothDevice, error) {
	if runtime.GOOS != "darwin" || !commandExists("system_profiler") {
		return nil, errors.New("system_profiler unavailable")
	}

	ctx, cancel := context.WithTimeout(context.Background(), systemProfilerTimeout)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPBluetoothDataType")
	if err != nil {
		return nil, err
	}
	return parseSPBluetooth(out), nil
}

func readBluetoothCTLDevices() ([]BluetoothDevice, error) {
	if !commandExists("bluetoothctl") {
		return nil, errors.New("bluetoothctl unavailable")
	}

	ctx, cancel := context.WithTimeout(context.Background(), bluetoothctlTimeout)
	defer cancel()

	out, err := runCmd(ctx, "bluetoothctl", "info")
	if err != nil {
		return nil, err
	}
	return parseBluetoothctl(out), nil
}

func parseSPBluetooth(raw string) []BluetoothDevice {
	var devices []BluetoothDevice
	var currentName string
	var connected bool
	var battery string

	for line := range strings.Lines(raw) {
		trim := strings.TrimSpace(line)
		if len(trim) == 0 {
			continue
		}
		if !strings.HasPrefix(line, "    ") && strings.HasSuffix(trim, ":") {
			// Reset at top-level sections.
			currentName = ""
			connected = false
			battery = ""
			continue
		}
		if strings.HasPrefix(line, "        ") && strings.HasSuffix(trim, ":") {
			if currentName != "" {
				devices = append(devices, BluetoothDevice{Name: currentName, Connected: connected, Battery: battery})
			}
			currentName = strings.TrimSuffix(trim, ":")
			connected = false
			battery = ""
			continue
		}
		if strings.Contains(trim, "Connected:") {
			connected = strings.Contains(trim, "Yes")
		}
		if strings.Contains(trim, "Battery Level:") {
			battery = strings.TrimSpace(strings.TrimPrefix(trim, "Battery Level:"))
		}
	}
	if currentName != "" {
		devices = append(devices, BluetoothDevice{Name: currentName, Connected: connected, Battery: battery})
	}
	if len(devices) == 0 {
		return []BluetoothDevice{{Name: "No devices", Connected: false}}
	}
	return devices
}

func parseBluetoothctl(raw string) []BluetoothDevice {
	var devices []BluetoothDevice
	current := BluetoothDevice{}
	for line := range strings.Lines(raw) {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "Device ") {
			if current.Name != "" {
				devices = append(devices, current)
			}
			current = BluetoothDevice{Name: strings.TrimPrefix(trim, "Device "), Connected: false}
		}
		if after, ok := strings.CutPrefix(trim, "Name:"); ok {
			current.Name = strings.TrimSpace(after)
		}
		if strings.HasPrefix(trim, "Connected:") {
			current.Connected = strings.Contains(trim, "yes")
		}
	}
	if current.Name != "" {
		devices = append(devices, current)
	}
	if len(devices) == 0 {
		return []BluetoothDevice{{Name: "No devices", Connected: false}}
	}
	return devices
}
