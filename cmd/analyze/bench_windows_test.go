//go:build windows

package main

// Benchmarks for the enumeration primitive. P1 of the hardlink dedup plan uses
// them to compare two complete scans; these micro-benchmarks only show whether
// the primitive itself is more expensive than os.ReadDir on the same tree.

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/windows"
)

type benchFixture struct {
	name  string
	files int
	links int
	dirs  int
}

var benchFixtures = []benchFixture{
	{name: "wide-2000-links-2000", files: 2000, links: 2000, dirs: 50},
	{name: "wide-4000-no-links", files: 4000, links: 0, dirs: 50},
	{name: "single-dir-5000", files: 5000, links: 0, dirs: 1},
}

// newBenchTree builds one tree with unique files plus hard links to them. Hard
// links are what the fixture exists for, so a volume that refuses them skips the
// benchmark instead of measuring something else.
func newBenchTree(b *testing.B, fixture benchFixture) string {
	b.Helper()
	root := b.TempDir()
	dirs := make([]string, fixture.dirs)
	for index := range dirs {
		dirs[index] = filepath.Join(root, fmt.Sprintf("dir%04d", index))
		if err := os.Mkdir(dirs[index], 0o755); err != nil {
			b.Fatalf("mkdir %s: %v", dirs[index], err)
		}
	}

	content := make([]byte, 4096)
	targets := make([]string, fixture.files)
	for index := range targets {
		targets[index] = filepath.Join(root, fmt.Sprintf("blob%05d.bin", index))
		if err := os.WriteFile(targets[index], content, 0o644); err != nil {
			b.Fatalf("write %s: %v", targets[index], err)
		}
	}
	for index := 0; index < fixture.links; index++ {
		link := filepath.Join(dirs[index%len(dirs)], fmt.Sprintf("link%05d.bin", index))
		if err := os.Link(targets[index%len(targets)], link); err != nil {
			b.Skipf("this volume cannot create hard links: %v", err)
		}
	}
	return root
}

// sumOSReadDir is the walker cost today: os.ReadDir plus the cached Info the
// file system already returned.
func sumOSReadDir(root string) (int64, error) {
	var total int64
	walkErr := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		info, infoErr := entry.Info()
		if infoErr != nil {
			return infoErr
		}
		total += info.Size()
		return nil
	})
	return total, walkErr
}

// sumIdentities is the candidate cost: one handle per directory and the same
// number of file-system calls, with the file ID and allocation decoded.
func sumIdentities(root string) (int64, bool, error) {
	var total int64
	hasIdentities := true
	pending := []string{root}
	for len(pending) > 0 {
		path := pending[len(pending)-1]
		pending = pending[:len(pending)-1]
		entries, identities, enumErr := readDirWithIdentities(path)
		if enumErr != nil {
			return total, hasIdentities, enumErr
		}
		if !identities {
			hasIdentities = false
		}
		for _, child := range entries {
			if child.Attributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0 && child.Attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT == 0 {
				pending = append(pending, filepath.Join(path, child.Name))
				continue
			}
			total += child.Size
		}
	}
	return total, hasIdentities, nil
}

func BenchmarkDirEnumeration(b *testing.B) {
	for _, fixture := range benchFixtures {
		b.Run(fixture.name, func(b *testing.B) {
			root := newBenchTree(b, fixture)

			b.Run("os.ReadDir", func(b *testing.B) {
				b.ReportAllocs()
				for range b.N {
					if _, err := sumOSReadDir(root); err != nil {
						b.Fatalf("walk: %v", err)
					}
				}
			})

			b.Run("readDirWithIdentities", func(b *testing.B) {
				b.ReportAllocs()
				_, hasIdentities, err := sumIdentities(root)
				if err != nil {
					b.Fatalf("walk: %v", err)
				}
				if !hasIdentities {
					b.Skip("this volume does not report file IDs")
				}
				b.ResetTimer()
				for range b.N {
					if _, _, walkErr := sumIdentities(root); walkErr != nil {
						b.Fatalf("walk: %v", walkErr)
					}
				}
			})
		})
	}
}
