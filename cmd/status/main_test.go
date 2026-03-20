package main

import (
	"os"
	"testing"
	"time"
)

func TestShouldUseJSONOutput_ForceFlag(t *testing.T) {
	if !shouldUseJSONOutput(true, nil) {
		t.Fatalf("expected force JSON flag to enable JSON mode")
	}
}

func TestShouldUseJSONOutput_NilStdout(t *testing.T) {
	if shouldUseJSONOutput(false, nil) {
		t.Fatalf("expected nil stdout to keep TUI mode")
	}
}

func TestShouldUseJSONOutput_NonTTYPipe(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("create pipe: %v", err)
	}
	defer reader.Close()
	defer writer.Close()

	if !shouldUseJSONOutput(false, writer) {
		t.Fatalf("expected pipe stdout to use JSON mode")
	}
}

func TestShouldUseJSONOutput_NonTTYFile(t *testing.T) {
	tmpFile, err := os.CreateTemp("", "mole-status-stdout-*.txt")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	if !shouldUseJSONOutput(false, tmpFile) {
		t.Fatalf("expected file stdout to use JSON mode")
	}
}

func TestProcessWatchOptionsFromFlags(t *testing.T) {
	oldThreshold := *procCPUThreshold
	oldWindow := *procCPUWindow
	oldAlerts := *procCPUAlerts
	defer func() {
		*procCPUThreshold = oldThreshold
		*procCPUWindow = oldWindow
		*procCPUAlerts = oldAlerts
	}()

	*procCPUThreshold = 125
	*procCPUWindow = 2 * time.Minute
	*procCPUAlerts = false

	opts := processWatchOptionsFromFlags()
	if opts.CPUThreshold != 125 {
		t.Fatalf("CPUThreshold = %v, want 125", opts.CPUThreshold)
	}
	if opts.Window != 2*time.Minute {
		t.Fatalf("Window = %v, want 2m", opts.Window)
	}
	if opts.Enabled {
		t.Fatal("Enabled = true, want false")
	}
}

func TestValidateFlags(t *testing.T) {
	oldThreshold := *procCPUThreshold
	oldWindow := *procCPUWindow
	defer func() {
		*procCPUThreshold = oldThreshold
		*procCPUWindow = oldWindow
	}()

	*procCPUThreshold = -1
	*procCPUWindow = 5 * time.Minute
	if err := validateFlags(); err == nil {
		t.Fatal("expected negative threshold to fail validation")
	}

	*procCPUThreshold = 100
	*procCPUWindow = 0
	if err := validateFlags(); err == nil {
		t.Fatal("expected zero window to fail validation")
	}
}
