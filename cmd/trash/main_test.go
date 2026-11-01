//go:build linux

package main

import (
	"strings"
	"testing"
)

func TestFieldKeepsOnePathOnOneLine(t *testing.T) {
	got := field("/home/u/a\nok\t/home/u/b\\c")
	if strings.ContainsAny(got, "\n\t") {
		t.Fatalf("field left a separator: %q", got)
	}
	if got != `/home/u/a\nok\t/home/u/b\\c` {
		t.Fatalf("field = %q", got)
	}
}