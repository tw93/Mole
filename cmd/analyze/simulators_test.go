//go:build darwin

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
	"golang.org/x/sys/unix"
)

const simulatorTestUUID = "12345678-1234-1234-1234-123456789ABC"

func simulatorTestPlist(uuid, name string) string {
	return `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>UDID</key><string>` + uuid + `</string>
<key>name</key><string>` + name + `</string>
<key>runtime</key><string>com.apple.CoreSimulator.SimRuntime.iOS-26-5</string>
<key>state</key><integer>3</integer>
<key>lastUsedAt</key><date>2025-01-02T03:04:05Z</date>
<key>isDeleted</key><false/>
<key>nested</key><dict><key>name</key><string>Wrong nested name</string></dict>
</dict></plist>`
}

func simulatorFixture(t *testing.T) (model, string) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	root := simulatorDevicesPath()
	path := filepath.Join(root, simulatorTestUUID)
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "device.plist"), []byte(simulatorTestPlist(simulatorTestUUID, "iPhone Test")), 0o600); err != nil {
		t.Fatal(err)
	}
	entry := dirEntry{Name: simulatorTestUUID, Path: path, IsDir: true, Size: 4_000_000}
	m := newModel(root, false)
	m.entries = []dirEntry{entry}
	m.entriesAll = m.entries
	m.scanning = false
	m.width, m.height = 120, 24
	t.Cleanup(func() { m.stopMeasurementsForExit() })
	return m, path
}

func loadSimulatorFixture(t *testing.T, m model) model {
	t.Helper()
	cmd := m.refreshSimulatorMetadata()
	updated, _ := m.Update(cmd())
	return updated.(model)
}

func TestSimulatorMetadataXMLAndBinary(t *testing.T) {
	for _, binary := range []bool{false, true} {
		t.Run(fmt.Sprintf("binary=%t", binary), func(t *testing.T) {
			m, path := simulatorFixture(t)
			if binary {
				cmd := exec.Command("/usr/bin/plutil", "-convert", "binary1", filepath.Join(path, "device.plist"))
				if output, err := cmd.CombinedOutput(); err != nil {
					t.Fatalf("convert fixture: %v: %s", err, output)
				}
			}
			m = loadSimulatorFixture(t, m)
			info, found := m.simulators[path]
			if !found || info.name != "iPhone Test" || info.runtime != "iOS 26.5" {
				t.Fatalf("incorrect device metadata: %+v", info)
			}
			if m.entries[0].Name != simulatorTestUUID || m.entries[0].Path != path {
				t.Fatal("metadata changed the underlying filesystem identity")
			}
		})
	}
}

func TestSimulatorMetadataUnknownAndMalformed(t *testing.T) {
	tests := []struct {
		name  string
		plist string
		fail  bool
	}{
		{"missing optional fields", `<plist><dict><key>UDID</key><string>` + simulatorTestUUID + `</string></dict></plist>`, false},
		{"malformed", `<plist><dict>`, true},
		{"wrong identifier", simulatorTestPlist("different", "iPhone"), true},
		{"duplicate key", strings.Replace(simulatorTestPlist(simulatorTestUUID, "iPhone"), "<key>nested</key>", "<key>name</key>", 1), true},
		{"missing identifier", `<plist><dict/></plist>`, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			info, err := parseSimulatorPlist([]byte(test.plist), simulatorTestUUID)
			if (err != nil) != test.fail {
				t.Fatalf("parse error = %v, want failure %t", err, test.fail)
			}
			if !test.fail && (info.name != "" || info.runtime != "") {
				t.Fatalf("missing fields invented a device: %+v", info)
			}
		})
	}
	plist := simulatorTestPlist(simulatorTestUUID, "中文 &amp; 👩‍💻&#10;Device")
	info, err := parseSimulatorPlist([]byte(plist), simulatorTestUUID)
	if err != nil || info.name != "中文 & 👩‍💻 Device" {
		t.Fatalf("unsafe text in device name: %+v, %v", info, err)
	}
}

func TestSimulatorMetadataRejectsUnsafeFiles(t *testing.T) {
	for _, kind := range []string{"symlink", "fifo", "oversized", "directory", "device symlink"} {
		t.Run(kind, func(t *testing.T) {
			_, path := simulatorFixture(t)
			plist := filepath.Join(path, "device.plist")
			if err := os.Remove(plist); err != nil {
				t.Fatal(err)
			}
			var err error
			switch kind {
			case "symlink":
				target := filepath.Join(t.TempDir(), "other.plist")
				err = os.WriteFile(target, []byte(simulatorTestPlist(simulatorTestUUID, "Other")), 0o600)
				if err == nil {
					err = os.Symlink(target, plist)
				}
			case "fifo":
				err = unix.Mkfifo(plist, 0o600)
			case "oversized":
				err = os.WriteFile(plist, []byte(strings.Repeat("x", simulatorPlistLimit+1)), 0o600)
			case "directory":
				err = os.Mkdir(plist, 0o700)
			case "device symlink":
				err = os.Remove(path)
				if err == nil {
					err = os.Symlink(t.TempDir(), path)
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			if _, err := readSimulatorInfo(ctx, path); err == nil {
				t.Fatal("unsafe metadata file was accepted")
			}
		})
	}
	var output simulatorPlistOutput
	if _, err := output.Write(make([]byte, simulatorPlistLimit*4+1)); err == nil {
		t.Fatal("converter output is unbounded")
	}
}

func TestSimulatorMetadataRefreshRejectsOldResults(t *testing.T) {
	m, path := simulatorFixture(t)
	first := m.refreshSimulatorMetadata()
	firstResult := first().(simulatorMetadataMsg)
	if err := os.WriteFile(filepath.Join(path, "device.plist"), []byte(simulatorTestPlist(simulatorTestUUID, "Renamed device")), 0o600); err != nil {
		t.Fatal(err)
	}
	second := m.refreshSimulatorMetadata()
	updated, _ := m.Update(firstResult)
	m = updated.(model)
	if len(m.simulators) != 0 {
		t.Fatal("superseded metadata was applied")
	}
	updated, _ = m.Update(second())
	m = updated.(model)
	if m.simulators[path].name != "Renamed device" {
		t.Fatal("refresh did not read changed metadata")
	}
	pending := m.refreshSimulatorMetadata()
	m.path = t.TempDir()
	m.refreshSimulatorMetadata()
	updated, _ = m.Update(pending())
	if len(updated.(model).simulators) != 0 {
		t.Fatal("cancelled metadata leaked into another directory")
	}
}

func TestSimulatorMetadataCancelledBeforeDispatch(t *testing.T) {
	m, _ := simulatorFixture(t)
	command := m.refreshSimulatorMetadata()
	m.simulatorCancel()
	message := command().(simulatorMetadataMsg)
	if len(message.devices) != 0 {
		t.Fatal("cancelled probe read devices")
	}
}

func TestSimulatorViewFilterAndConfirmationKeepPath(t *testing.T) {
	m, path := simulatorFixture(t)
	m = loadSimulatorFixture(t, m)
	for _, query := range []string{"iphone test", "IOS 26.5", "123456789ABC"} {
		m.entryFilter = query
		m.applyEntryFilter()
		if len(m.entries) != 1 || m.entries[0].Path != path {
			t.Fatalf("query %q failed to find the correct path", query)
		}
	}
	m.entryFilter = ""
	m.applyEntryFilter()
	view := ansi.Strip(m.View())
	if !strings.Contains(view, "iPhone Test · iOS 26.5 · 12345678") {
		t.Fatalf("row does not name the device:\n%s", view)
	}
	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyBackspace})
	m = updated.(model)
	if !m.deleteConfirm || m.deleteTarget.Path != path || m.deleteTarget.Name != simulatorTestUUID {
		t.Fatal("confirmation lost the original device path")
	}
	view = ansi.Strip(m.View())
	if !strings.Contains(view, "Move to Trash: iPhone Test · iOS 26.5 · 12345678") {
		t.Fatalf("confirmation does not identify the device:\n%s", view)
	}
}

func TestSimulatorMetadataFailureKeepsUUID(t *testing.T) {
	m, path := simulatorFixture(t)
	m = loadSimulatorFixture(t, m)
	if err := os.Remove(filepath.Join(path, "device.plist")); err != nil {
		t.Fatal(err)
	}
	m = loadSimulatorFixture(t, m)
	if got := m.entryDisplayName(m.entries[0]); got != simulatorTestUUID {
		t.Fatalf("failed read retained an old label: %q", got)
	}
	if strings.Contains(ansi.Strip(m.View()), "iPhone Test") {
		t.Fatal("failed metadata refresh retained an old name")
	}
}

func TestSimulatorMetadataRefreshPrunesHiddenSelections(t *testing.T) {
	m, path := simulatorFixture(t)
	m = loadSimulatorFixture(t, m)
	m.entryFilter = "iphone"
	m.applyEntryFilter()
	m.multiSelected[path] = true
	if err := os.WriteFile(filepath.Join(path, "device.plist"), []byte(simulatorTestPlist(simulatorTestUUID, "iPad")), 0o600); err != nil {
		t.Fatal(err)
	}
	m = loadSimulatorFixture(t, m)
	if len(m.entries) != 0 || len(m.multiSelected) != 0 {
		t.Fatal("refresh left hidden selected devices")
	}
}

func TestSimulatorMetadataDoesNotChangePendingConfirmation(t *testing.T) {
	m, path := simulatorFixture(t)
	m = loadSimulatorFixture(t, m)
	m.deleteConfirm = true
	m.deleteTarget = &m.entries[0]
	updated, _ := m.Update(simulatorMetadataMsg{
		id: m.simulatorProbeID, path: m.path,
		devices: map[string]simulatorInfo{path: {name: "Different name"}},
	})
	got := updated.(model)
	if got.simulators[path].name != "iPhone Test" || got.deleteTarget.Path != path {
		t.Fatal("asynchronous metadata changed an outstanding confirmation")
	}
}

func TestSimulatorMetadataNavigationAndLiveScan(t *testing.T) {
	m, path := simulatorFixture(t)
	m = loadSimulatorFixture(t, m)
	originalID := m.simulatorProbeID
	m.cache[path] = historyEntry{Path: path, Entries: []dirEntry{{Name: "data", Path: filepath.Join(path, "data"), IsDir: true, Size: 10}}}
	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyEnter})
	child := updated.(model)
	if len(child.simulators) != 0 || child.path != path {
		t.Fatal("leaving the devices directory retained metadata")
	}
	updated, command := child.Update(tea.KeyMsg{Type: tea.KeyLeft})
	back := updated.(model)
	if back.path != m.path || back.simulatorProbeID <= originalID || command == nil {
		t.Fatal("returning to a warm directory did not refresh device metadata")
	}
	back.stopMeasurementsForExit()
	m.liveScanID = 5
	m.liveScanEvents = make(chan liveScanEventMsg)
	m.cache = make(map[string]historyEntry)
	updated, _ = m.Update(liveScanEventMsg{id: 5, path: m.path, kind: liveScanChildProgress, entry: dirEntry{
		Name: simulatorTestUUID, Path: path, IsDir: true, Size: 9_000_000,
	}})
	if got := updated.(model).entryDisplayName(m.entries[0]); !strings.Contains(got, "iPhone Test") {
		t.Fatal("live sizing dropped simulator metadata")
	}
}

func TestSimulatorMetadataProbesOnlyTheDevicesDirectory(t *testing.T) {
	m, _ := simulatorFixture(t)
	m.path = filepath.Dir(m.path)
	if command := m.refreshSimulatorMetadata(); command != nil {
		t.Fatal("another directory started a device metadata probe")
	}
}

func TestSimulatorNamesReplaceOnlyDeviceRows(t *testing.T) {
	m, path := simulatorFixture(t)
	m = loadSimulatorFixture(t, m)
	info := m.simulators[path]
	elsewhere := filepath.Join(t.TempDir(), simulatorTestUUID)
	m.simulators[elsewhere] = info
	cases := []dirEntry{
		{Name: simulatorTestUUID, Path: elsewhere, IsDir: true},
		{Name: simulatorTestUUID, Path: path, IsDir: false},
		{Name: "renamed", Path: path, IsDir: true},
	}
	for _, entry := range cases {
		if got := m.entryDisplayName(entry); got != entry.Name {
			t.Fatalf("%+v displayed as %q", entry, got)
		}
	}
}
