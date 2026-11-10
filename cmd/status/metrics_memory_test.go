package main

import (
	"context"
	"errors"
	"runtime"
	"strings"
	"testing"
)

func TestParseMemoryPressureLevel(t *testing.T) {
	// kern.memorystatus_vm_pressure_level reports the dispatch levels.
	for _, tc := range []struct{ out, want string }{
		{"1\n", "normal"},
		{"2\n", "warn"},
		{"4\n", "critical"},
	} {
		if got := parseMemoryPressureLevel(tc.out); got != tc.want {
			t.Fatalf("level %q: expected %q, got %q", tc.out, tc.want, got)
		}
	}

	// An empty read, an undefined level, or the summary line memory_pressure
	// prints reports nothing rather than a guessed level.
	for _, out := range []string{"", "0\n", "3\n", "normal\n", "System-wide memory free percentage: 86%\n"} {
		if got := parseMemoryPressureLevel(out); got != "" {
			t.Fatalf("unusable output %q: expected no level, got %q", out, got)
		}
	}
}

func TestGetMemoryPressureReadsKernelLevel(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("memory pressure is a macOS probe")
	}
	origRunCmd := runCmd
	t.Cleanup(func() { runCmd = origRunCmd })

	// memory_pressure never names the level, so only the sysctl can answer
	// (#1963). It runs by absolute path because PATH may leave out /usr/sbin
	// (#1804).
	runCmd = func(_ context.Context, name string, args ...string) (string, error) {
		if name == "/usr/sbin/sysctl" && strings.Join(args, " ") == "-n kern.memorystatus_vm_pressure_level" {
			return "2\n", nil
		}
		return "System-wide memory free percentage: 86%\n", nil
	}
	if got := getMemoryPressure(); got != "warn" {
		t.Fatalf("expected warn from the kernel level, got %q", got)
	}

	runCmd = func(context.Context, string, ...string) (string, error) {
		return "", errors.New("sysctl unavailable")
	}
	if got := getMemoryPressure(); got != "" {
		t.Fatalf("a failed read must report no level, got %q", got)
	}
}
