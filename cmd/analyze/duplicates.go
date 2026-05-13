//go:build darwin

package main

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"
)

const maxDuplicateGroups = 50

type duplicateCandidate struct {
	Name string
	Path string
	Size int64
	ID   string
}

func findDuplicateGroupsForJSON(root string, minSize int64) []jsonDuplicateGroup {
	if minSize < 1 {
		minSize = 1
	}

	candidatesBySize := make(map[int64][]duplicateCandidate)
	seenIDs := make(map[string]bool)

	_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if path != root && entry.IsDir() {
			name := entry.Name()
			if defaultSkipDirs[name] || (root == "/" && skipSystemDirs[name]) {
				return filepath.SkipDir
			}
			return nil
		}
		if entry.Type()&fs.ModeSymlink != 0 || entry.IsDir() {
			return nil
		}

		info, err := entry.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() < minSize {
			return nil
		}

		id := fileIdentity(info)
		if id != "" {
			if seenIDs[id] {
				return nil
			}
			seenIDs[id] = true
		}

		size := info.Size()
		candidatesBySize[size] = append(candidatesBySize[size], duplicateCandidate{
			Name: entry.Name(),
			Path: path,
			Size: size,
			ID:   id,
		})
		return nil
	})

	groups := make([]jsonDuplicateGroup, 0)
	for size, candidates := range candidatesBySize {
		if len(candidates) < 2 {
			continue
		}
		byHash := make(map[string][]duplicateCandidate)
		for _, candidate := range candidates {
			hash, err := hashFile(candidate.Path)
			if err != nil {
				continue
			}
			byHash[hash] = append(byHash[hash], candidate)
		}
		for hash, matches := range byHash {
			if len(matches) < 2 {
				continue
			}
			sort.SliceStable(matches, func(i, j int) bool {
				return matches[i].Path < matches[j].Path
			})
			files := make([]jsonFileEntry, 0, len(matches))
			for _, match := range matches {
				files = append(files, jsonFileEntry{Name: match.Name, Path: match.Path, Size: match.Size})
			}
			groups = append(groups, jsonDuplicateGroup{
				Hash:        hash,
				Size:        size,
				WastedBytes: size * int64(len(matches)-1),
				Files:       files,
			})
		}
	}

	sort.SliceStable(groups, func(i, j int) bool {
		if groups[i].WastedBytes == groups[j].WastedBytes {
			return groups[i].Size > groups[j].Size
		}
		return groups[i].WastedBytes > groups[j].WastedBytes
	})
	if len(groups) > maxDuplicateGroups {
		groups = groups[:maxDuplicateGroups]
	}
	return groups
}

func fileIdentity(info os.FileInfo) string {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	return strconv.FormatInt(int64(stat.Dev), 10) + ":" + strconv.FormatUint(stat.Ino, 10)
}

func hashFile(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	sum := sha256.New()
	if _, err := io.Copy(sum, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}
