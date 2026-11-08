package main

import (
	"os"
	"testing"
	"time"
)

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
