//go:build darwin

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"syscall"
	"time"
)

const maxDuplicateGroups = 50

var errDuplicateScanStopped = errors.New("duplicate scan stopped")

type duplicateCandidate struct {
	Name string
	Path string
	Size int64
	ID   string
}

type duplicateScanResult struct {
	Groups []jsonDuplicateGroup
	Scan   jsonDuplicateScan
}

func findDuplicateGroupsForJSON(root string, minSize int64, timeout time.Duration, maxCandidates int) duplicateScanResult {
	started := time.Now()
	if minSize < 1 {
		minSize = 1
	}

	ctx := context.Background()
	cancel := func() {}
	if timeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, timeout)
	}
	defer cancel()

	scan := jsonDuplicateScan{
		TimeoutMS:     int64(timeout / time.Millisecond),
		MaxCandidates: maxCandidates,
	}
	markPartial := func(reason string) {
		if !scan.Partial {
			scan.Partial = true
			scan.Reason = reason
		}
	}
	finish := func(groups []jsonDuplicateGroup) duplicateScanResult {
		scan.Groups = len(groups)
		scan.DurationMS = time.Since(started).Milliseconds()
		return duplicateScanResult{Groups: groups, Scan: scan}
	}

	candidatesBySize := make(map[int64][]duplicateCandidate)
	seenIDs := make(map[string]bool)

	walkErr := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if ctx.Err() != nil {
			markPartial("timeout")
			return errDuplicateScanStopped
		}
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
		scan.Candidates++
		if maxCandidates > 0 && scan.Candidates >= maxCandidates {
			markPartial("candidate_limit")
			return errDuplicateScanStopped
		}
		return nil
	})
	if walkErr != nil && !errors.Is(walkErr, errDuplicateScanStopped) {
		markPartial("walk_error")
		return finish(nil)
	}

	groups := make([]jsonDuplicateGroup, 0)
	for size, candidates := range candidatesBySize {
		if ctx.Err() != nil {
			markPartial("timeout")
			break
		}
		if len(candidates) < 2 {
			continue
		}
		byHash := make(map[string][]duplicateCandidate)
		for _, candidate := range candidates {
			if ctx.Err() != nil {
				markPartial("timeout")
				break
			}
			hash, err := hashFileContext(ctx, candidate.Path)
			if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
				markPartial("timeout")
				break
			}
			if err != nil {
				continue
			}
			scan.HashedFiles++
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
		scan.TruncatedGroups = true
		groups = groups[:maxDuplicateGroups]
	}
	return finish(groups)
}

func fileIdentity(info os.FileInfo) string {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	return strconv.FormatInt(int64(stat.Dev), 10) + ":" + strconv.FormatUint(stat.Ino, 10)
}

func hashFileContext(ctx context.Context, path string) (hash string, err error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer func() {
		if closeErr := file.Close(); err == nil && closeErr != nil {
			err = closeErr
		}
	}()

	sum := sha256.New()
	buf := make([]byte, 1024*1024)
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n, readErr := file.Read(buf)
		if n > 0 {
			if _, err := sum.Write(buf[:n]); err != nil {
				return "", err
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return "", readErr
		}
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}
