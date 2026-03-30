//go:build darwin

package main

import "testing"

func TestSystemProcessesExclusion(t *testing.T) {
	// Verify expected system processes are in the exclusion set.
	expected := []string{
		"kernel_task",
		"WindowServer",
		"mds",
		"mds_stores",
		"distnoted",
		"launchd",
		"syslogd",
		"opendirectoryd",
	}

	for _, name := range expected {
		if !systemProcesses[name] {
			t.Errorf("expected %q in systemProcesses map", name)
		}
	}
}

func TestSystemProcessesDoesNotExcludeUserApps(t *testing.T) {
	// User applications should NOT be in the system processes exclusion map.
	userApps := []string{"Chrome", "Slack", "docker", "node", "python3"}
	for _, name := range userApps {
		if systemProcesses[name] {
			t.Errorf("%q should NOT be in systemProcesses exclusion map", name)
		}
	}
}
