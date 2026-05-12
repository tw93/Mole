//go:build darwin

package main

import (
	"context"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func skipIfFinderUnavailable(t *testing.T) {
	t.Helper()

	if os.Getenv("CI") != "" {
		t.Skip("Skipping Finder-dependent test in CI")
	}
	if os.Getenv("ROOMY_SKIP_FINDER_TESTS") == "1" {
		t.Skip("Skipping Finder-dependent test via ROOMY_SKIP_FINDER_TESTS")
	}
	if _, err := exec.LookPath("osascript"); err != nil {
		t.Skipf("Skipping Finder-dependent test, osascript unavailable: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "osascript", "-e", `tell application "Finder" to get name`)
	output, err := cmd.CombinedOutput()
	text := strings.ToLower(string(output))
	if ctx.Err() == context.DeadlineExceeded {
		t.Skip("Skipping Finder-dependent test, Finder probe timed out")
	}
	if strings.Contains(text, "connection invalid") || strings.Contains(text, "can’t get application \"finder\"") || strings.Contains(text, "can't get application \"finder\"") {
		t.Skipf("Skipping Finder-dependent test, Finder probe indicates unavailable session: %s", strings.TrimSpace(string(output)))
	}
	if err != nil {
		reason := strings.TrimSpace(string(output))
		if reason == "" {
			reason = err.Error()
		}
		t.Skipf("Skipping Finder-dependent test, Finder unavailable: %s", reason)
	}
}
