//go:build darwin

package main

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
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
	name    string
	runtime string
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
	info := simulatorInfo{}
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
