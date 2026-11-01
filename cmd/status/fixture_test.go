package main

import (
	"os"
	"path/filepath"
	"testing"
)

// writeTree creates files (relative path to content) under a fresh temp root,
// so readers that take a root path never touch the live /sys or /proc.
func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	root := t.TempDir()
	addTree(t, root, files)
	return root
}

func addTree(t *testing.T, root string, files map[string]string) {
	t.Helper()
	for rel, content := range files {
		path := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func findCard(t *testing.T, cards []cardData, title string) cardData {
	t.Helper()
	for _, c := range cards {
		if c.title == title {
			return c
		}
	}
	t.Fatalf("no %q card among %d cards", title, len(cards))
	return cardData{}
}
