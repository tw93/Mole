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
	if os.Getenv("MOLE_SKIP_FINDER_TESTS") == "1" {
		t.Skip("Skipping Finder-dependent test via MOLE_SKIP_FINDER_TESTS")
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

// useDuStub points the size probe at a stub du for the rest of the test.
func useDuStub(t *testing.T, stub string) {
	t.Helper()
	previous := duBinary
	duBinary = stub
	t.Cleanup(func() { duBinary = previous })
}

// scanHome returns a HOME for a test that applies a scan result. Applying one
// saves the cache in a goroutine nothing waits for, so a write can land while
// t.TempDir's cleanup is removing the folder and fail a test whose assertions
// all passed. This cleanup retries until that write has finished.
func scanHome(t *testing.T) string {
	t.Helper()
	home, err := os.MkdirTemp("", "mole-analyze-home-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		deadline := time.Now().Add(5 * time.Second)
		for {
			err := os.RemoveAll(home)
			if err == nil {
				return
			}
			if time.Now().After(deadline) {
				t.Errorf("remove test home: %v", err)
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	})
	return home
}
