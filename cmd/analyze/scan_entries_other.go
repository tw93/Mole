//go:build !windows

package main

import (
	"io/fs"
	"os"
)

type scanDirEntry struct {
	record   *idBothDirEntry
	fallback fs.DirEntry
}

func readScanEntries(path string) ([]scanDirEntry, error) {
	entries, err := os.ReadDir(path)
	if err != nil {
		return nil, err
	}
	result := make([]scanDirEntry, len(entries))
	for index, entry := range entries {
		result[index].fallback = entry
	}
	return result, nil
}

func (e scanDirEntry) Name() string               { return e.fallback.Name() }
func (e scanDirEntry) IsDir() bool                { return e.fallback.IsDir() }
func (e scanDirEntry) Type() fs.FileMode          { return e.fallback.Type() }
func (e scanDirEntry) Info() (fs.FileInfo, error) { return e.fallback.Info() }
