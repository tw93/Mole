package main

import "testing"

// useDuStub points the size probe at a stub du for the rest of the test.
func useDuStub(t *testing.T, stub string) {
	t.Helper()
	previous := duBinary
	duBinary = stub
	t.Cleanup(func() { duBinary = previous })
}
