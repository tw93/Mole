//go:build darwin

package main

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"time"
	"unicode"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
	"golang.org/x/sys/unix"
)

const simulatorProbeTimeout = 3 * time.Second
const simulatorPlistLimit = 64 * 1024

var simulatorUUIDPattern = regexp.MustCompile(`(?i)^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)
var simulatorRuntimePattern = regexp.MustCompile(`^com\.apple\.CoreSimulator\.SimRuntime\.(iOS|tvOS|watchOS|xrOS|visionOS)-([0-9]+(?:-[0-9]+)*)$`)
var activeSimulatorCommands atomic.Int64

type simulatorInfo struct {
	name     string
	runtime  string
	state    string
	lastUsed time.Time
}

type simulatorMetadataMsg struct {
	id      uint64
	path    string
	devices map[string]simulatorInfo
}

type simulatorPlistValue struct {
	XMLName xml.Name
	Text    string `xml:",chardata"`
}

func simulatorDevicesPath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, "Library", "Developer", "CoreSimulator", "Devices")
}

func isSimulatorEntry(entry dirEntry) bool {
	return entry.IsDir && filepath.Dir(entry.Path) == simulatorDevicesPath() &&
		simulatorUUIDPattern.MatchString(filepath.Base(entry.Path)) &&
		entry.Name == filepath.Base(entry.Path)
}

func parseSimulatorPlist(data []byte, uuid string) (simulatorInfo, error) {
	var document struct {
		XMLName xml.Name `xml:"plist"`
		Dict    struct {
			Values []simulatorPlistValue `xml:",any"`
		} `xml:"dict"`
	}
	if err := xml.Unmarshal(data, &document); err != nil {
		return simulatorInfo{}, err
	}
	values := document.Dict.Values
	fields := make(map[string]simulatorPlistValue)
	for index := 0; index < len(values); index += 2 {
		if index+1 >= len(values) || values[index].XMLName.Local != "key" {
			return simulatorInfo{}, errors.New("invalid simulator dictionary")
		}
		key := values[index].Text
		if _, exists := fields[key]; exists {
			return simulatorInfo{}, errors.New("duplicate simulator key")
		}
		fields[key] = values[index+1]
	}
	if fields["UDID"].XMLName.Local != "string" || !strings.EqualFold(fields["UDID"].Text, uuid) {
		return simulatorInfo{}, errors.New("simulator identifier mismatch")
	}
	info := simulatorInfo{state: "Unknown"}
	if fields["name"].XMLName.Local == "string" {
		info.name = strings.TrimSpace(strings.Map(func(char rune) rune {
			if unicode.IsControl(char) {
				return ' '
			}
			return char
		}, ansi.Strip(fields["name"].Text)))
	}
	if fields["runtime"].XMLName.Local == "string" {
		if parts := simulatorRuntimePattern.FindStringSubmatch(fields["runtime"].Text); len(parts) == 3 {
			platform := parts[1]
			if platform == "xrOS" {
				platform = "visionOS"
			}
			info.runtime = platform + " " + strings.ReplaceAll(parts[2], "-", ".")
		}
	}
	if fields["state"].XMLName.Local == "integer" {
		if state, found := map[string]string{
			"0": "Creating", "1": "Shutdown", "2": "Booting", "3": "Booted", "4": "Shutting down",
		}[strings.TrimSpace(fields["state"].Text)]; found {
			info.state = state
		}
	}
	if fields["isDeleted"].XMLName.Local == "true" {
		info.state = "Deleted"
	}
	if fields["lastUsedAt"].XMLName.Local == "date" {
		info.lastUsed, _ = time.Parse(time.RFC3339, strings.TrimSpace(fields["lastUsedAt"].Text))
		if info.lastUsed.After(time.Now()) {
			info.lastUsed = time.Time{}
		}
	}
	return info, nil
}

type simulatorPlistOutput struct {
	buffer bytes.Buffer
}

func (output *simulatorPlistOutput) Write(data []byte) (int, error) {
	if output.buffer.Len()+len(data) > simulatorPlistLimit*4 {
		return 0, errors.New("simulator plist output too large")
	}
	return output.buffer.Write(data)
}

func readSimulatorInfo(ctx context.Context, path string) (simulatorInfo, error) {
	if err := ctx.Err(); err != nil {
		return simulatorInfo{}, err
	}
	device, err := os.Lstat(path)
	if err != nil || !device.IsDir() || device.Mode()&os.ModeSymlink != 0 {
		return simulatorInfo{}, errors.New("simulator directory unavailable")
	}
	file, err := os.OpenFile(filepath.Join(path, "device.plist"), os.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return simulatorInfo{}, err
	}
	defer func() { _ = file.Close() }()
	stat, err := file.Stat()
	if err != nil || !stat.Mode().IsRegular() || stat.Size() > simulatorPlistLimit {
		return simulatorInfo{}, errors.New("invalid simulator plist file")
	}
	data, err := io.ReadAll(io.LimitReader(file, simulatorPlistLimit+1))
	if err != nil || len(data) > simulatorPlistLimit {
		return simulatorInfo{}, errors.New("simulator plist exceeds read limit")
	}
	if bytes.HasPrefix(data, []byte("bplist")) {
		probeCtx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
		defer cancel()
		command := exec.CommandContext(probeCtx, "/usr/bin/plutil", "-convert", "xml1", "-o", "-", "--", "-")
		command.Stdin = bytes.NewReader(data)
		var output simulatorPlistOutput
		command.Stdout = &output
		activeSimulatorCommands.Add(1)
		err := command.Run()
		activeSimulatorCommands.Add(-1)
		if err != nil {
			return simulatorInfo{}, err
		}
		data = output.buffer.Bytes()
	}
	return parseSimulatorPlist(data, filepath.Base(path))
}

func (m *model) refreshSimulatorMetadata() tea.Cmd {
	if m.simulatorCancel != nil {
		m.simulatorCancel()
		m.simulatorCancel = nil
	}
	m.simulatorProbeID++
	m.simulators = nil
	if m.path != simulatorDevicesPath() || m.inOverviewMode() {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), simulatorProbeTimeout)
	m.simulatorCancel = cancel
	id, path := m.simulatorProbeID, m.path
	return func() tea.Msg {
		defer cancel()
		devices := make(map[string]simulatorInfo)
		directory, err := os.Open(path)
		if err == nil {
			defer func() { _ = directory.Close() }()
			for ctx.Err() == nil {
				names, readErr := directory.Readdirnames(32)
				for _, name := range names {
					if ctx.Err() != nil {
						break
					}
					if !simulatorUUIDPattern.MatchString(name) {
						continue
					}
					devicePath := filepath.Join(path, name)
					if info, err := readSimulatorInfo(ctx, devicePath); err == nil {
						devices[devicePath] = info
					}
				}
				if readErr != nil {
					break
				}
			}
		}
		return simulatorMetadataMsg{id: id, path: path, devices: devices}
	}
}

func (m model) entryDisplayName(entry dirEntry) string {
	info, found := m.simulators[entry.Path]
	if !found || !isSimulatorEntry(entry) || info.name == "" {
		return entry.Name
	}
	name := info.name
	if info.runtime != "" {
		name += " · " + info.runtime
	}
	return name + " · " + entry.Name[:8]
}

func (m model) simulatorDetailLines() []string {
	if m.showLargeFiles || m.inOverviewMode() || m.selected < 0 || m.selected >= len(m.entries) {
		return nil
	}
	entry := m.entries[m.selected]
	if !isSimulatorEntry(entry) {
		return nil
	}
	info := m.simulators[entry.Path]
	name, runtime, state, used := info.name, info.runtime, info.state, "Unknown"
	if name == "" {
		name = "Unknown device"
	}
	if runtime == "" {
		runtime = "Unknown OS"
	}
	if state == "" {
		state = "Unknown"
	}
	if !info.lastUsed.IsZero() {
		used = info.lastUsed.Local().Format("2006-01-02")
	}
	text := truncateMiddle(name+" · "+runtime, max(m.width, 40)) + "\nUUID: " + filepath.Base(entry.Path) +
		"\nLast used: " + used + " · Recorded state: " + state
	return strings.Split(ansi.Hardwrap(text, max(m.width, 40), true), "\n")
}

func (m model) entryViewport() int {
	if m.height <= 0 {
		return calculateViewport(m.height, false)
	}
	reserved := len(m.simulatorDetailLines())
	if lines := m.simulatorConfirmationLines(); len(lines) > 0 {
		reserved += len(lines) + 1
	}
	return calculateViewport(max(1, m.height-reserved), false)
}

func (m model) hasSimulatorDeleteTarget() bool {
	if m.showLargeFiles {
		return false
	}
	if len(m.multiSelected) > 0 {
		for _, entry := range m.entries {
			if m.multiSelected[entry.Path] && isSimulatorEntry(entry) {
				return true
			}
		}
		return false
	}
	return m.deleteTarget != nil && isSimulatorEntry(*m.deleteTarget)
}

func (m model) simulatorConfirmationLines() []string {
	if !m.deleteConfirm || m.deleteTarget == nil || !m.hasSimulatorDeleteTarget() {
		return nil
	}
	label := m.entryDisplayName(*m.deleteTarget)
	size := measuredSizeLabel(m.deleteTarget.Size, m.deleteTarget.State)
	if len(m.multiSelected) > 1 {
		label = fmt.Sprintf("%d items", len(m.multiSelected))
		total, state := m.selectedEntryMeasurement()
		size = measuredSizeLabel(total, state)
	}
	text := "Move to Trash: " + truncateMiddle(label, max(m.width, 40)) + ", " + size +
		"\nSimulator device: includes installed apps and their data." +
		"\nPress Enter to confirm | Esc cancel"
	return strings.Split(ansi.Hardwrap(text, max(m.width, 40), true), "\n")
}
