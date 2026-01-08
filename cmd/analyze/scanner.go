package main

import (
	"bytes"
	"container/heap"
	"context"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sync/singleflight"
)

var scanGroup singleflight.Group

func scanPathConcurrent(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) (scanResult, error) {
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, err
	}

	var total int64

	// Keep Top N heaps.
	entriesHeap := &entryHeap{}
	heap.Init(entriesHeap)

	largeFilesHeap := &largeFileHeap{}
	heap.Init(largeFilesHeap)

	// Worker pool sized for I/O-bound scanning.
	numWorkers := max(runtime.NumCPU()*cpuMultiplier, minWorkers)
	if numWorkers > maxWorkers {
		numWorkers = maxWorkers
	}
	if numWorkers > len(children) {
		numWorkers = len(children)
	}
	if numWorkers < 1 {
		numWorkers = 1
	}
	sem := make(chan struct{}, numWorkers)
	var wg sync.WaitGroup

	// Collect results via channels.
	entryChan := make(chan dirEntry, len(children))
	largeFileChan := make(chan fileEntry, maxLargeFiles*2)

	var collectorWg sync.WaitGroup
	collectorWg.Add(2)
	go func() {
		defer collectorWg.Done()
		for entry := range entryChan {
			if entriesHeap.Len() < maxEntries {
				heap.Push(entriesHeap, entry)
			} else if entry.Size > (*entriesHeap)[0].Size {
				heap.Pop(entriesHeap)
				heap.Push(entriesHeap, entry)
			}
		}
	}()
	go func() {
		defer collectorWg.Done()
		for file := range largeFileChan {
			if largeFilesHeap.Len() < maxLargeFiles {
				heap.Push(largeFilesHeap, file)
			} else if file.Size > (*largeFilesHeap)[0].Size {
				heap.Pop(largeFilesHeap)
				heap.Push(largeFilesHeap, file)
			}
		}
	}()

	isRootDir := root == "/"
	home := os.Getenv("HOME")
	isHomeDir := home != "" && root == home

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		// Skip symlinks to avoid following unexpected targets.
		if child.Type()&fs.ModeSymlink != 0 {
			targetInfo, err := os.Stat(fullPath)
			isDir := false
			if err == nil && targetInfo.IsDir() {
				isDir = true
			}

			// Count link size only to avoid double-counting targets.
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			atomic.AddInt64(&total, size)

			entryChan <- dirEntry{
				Name:       child.Name() + " →",
				Path:       fullPath,
				Size:       size,
				IsDir:      isDir,
				LastAccess: getLastAccessTimeFromInfo(info),
			}
			continue
		}

		if child.IsDir() {
			if defaultSkipDirs[child.Name()] {
				continue
			}

			// Skip system dirs at root.
			if isRootDir && skipSystemDirs[child.Name()] {
				continue
			}

			// ~/Library is scanned separately; reuse cache when possible.
			if isHomeDir && child.Name() == "Library" {
				wg.Add(1)
				go func(name, path string) {
					defer wg.Done()
					sem <- struct{}{}
					defer func() { <-sem }()

					var size int64
					if cached, err := loadStoredOverviewSize(path); err == nil && cached > 0 {
						size = cached
					} else if cached, err := loadCacheFromDisk(path); err == nil {
						size = cached.TotalSize
					} else {
						size = calculateDirSizeConcurrent(path, largeFileChan, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					entryChan <- dirEntry{
						Name:       name,
						Path:       path,
						Size:       size,
						IsDir:      true,
						LastAccess: time.Time{},
					}
				}(child.Name(), fullPath)
				continue
			}

			// Folded dirs: fast size without expanding.
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				wg.Add(1)
				go func(name, path string) {
					defer wg.Done()
					sem <- struct{}{}
					defer func() { <-sem }()

					size, err := getDirectorySizeFromDu(path)
					if err != nil || size <= 0 {
						size = calculateDirSizeFast(path, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					entryChan <- dirEntry{
						Name:       name,
						Path:       path,
						Size:       size,
						IsDir:      true,
						LastAccess: time.Time{},
					}
				}(child.Name(), fullPath)
				continue
			}

			wg.Add(1)
			go func(name, path string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				size := calculateDirSizeConcurrent(path, largeFileChan, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, size)
				atomic.AddInt64(dirsScanned, 1)

				entryChan <- dirEntry{
					Name:       name,
					Path:       path,
					Size:       size,
					IsDir:      true,
					LastAccess: time.Time{},
				}
			}(child.Name(), fullPath)
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}
		// Actual disk usage for sparse/cloud files.
		size := getActualFileSize(fullPath, info)
		atomic.AddInt64(&total, size)
		atomic.AddInt64(filesScanned, 1)
		atomic.AddInt64(bytesScanned, size)

		entryChan <- dirEntry{
			Name:       child.Name(),
			Path:       fullPath,
			Size:       size,
			IsDir:      false,
			LastAccess: getLastAccessTimeFromInfo(info),
		}
		// Track large files only.
		if !shouldSkipFileForLargeTracking(fullPath) && size >= minLargeFileSize {
			largeFileChan <- fileEntry{Name: child.Name(), Path: fullPath, Size: size}
		}
	}

	wg.Wait()

	// Close channels and wait for collectors.
	close(entryChan)
	close(largeFileChan)
	collectorWg.Wait()

	// Convert heaps to sorted slices (descending).
	entries := make([]dirEntry, entriesHeap.Len())
	for i := len(entries) - 1; i >= 0; i-- {
		entries[i] = heap.Pop(entriesHeap).(dirEntry)
	}

	largeFiles := make([]fileEntry, largeFilesHeap.Len())
	for i := len(largeFiles) - 1; i >= 0; i-- {
		largeFiles[i] = heap.Pop(largeFilesHeap).(fileEntry)
	}

	// Use Spotlight for large files when available.
	if spotlightFiles := findLargeFilesWithSpotlight(root, minLargeFileSize); len(spotlightFiles) > 0 {
		largeFiles = spotlightFiles
	}

	return scanResult{
		Entries:    entries,
		LargeFiles: largeFiles,
		TotalSize:  total,
	}, nil
}

func shouldFoldDirWithPath(name, path string) bool {
	if foldDirs[name] {
		return true
	}

	// Handle npm cache structure.
	if strings.Contains(path, "/.npm/") || strings.Contains(path, "/.tnpm/") {
		parent := filepath.Base(filepath.Dir(path))
		if parent == ".npm" || parent == ".tnpm" || strings.HasPrefix(parent, "_") {
			return true
		}
		if len(name) == 1 {
			return true
		}
	}

	return false
}

func shouldSkipFileForLargeTracking(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	return skipExtensions[ext]
}

// calculateDirSizeFast performs concurrent dir sizing using os.ReadDir.
func calculateDirSizeFast(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) int64 {
	var total int64
	var wg sync.WaitGroup

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	concurrency := min(runtime.NumCPU()*4, 64)
	sem := make(chan struct{}, concurrency)

	var walk func(string)
	walk = func(dirPath string) {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if currentPath != nil && atomic.LoadInt64(filesScanned)%int64(batchUpdateSize) == 0 {
			*currentPath = dirPath
		}

		entries, err := os.ReadDir(dirPath)
		if err != nil {
			return
		}

		var localBytes, localFiles int64

		for _, entry := range entries {
			if entry.IsDir() {
				wg.Add(1)
				subDir := filepath.Join(dirPath, entry.Name())
				go func(p string) {
					defer wg.Done()
					sem <- struct{}{}
					defer func() { <-sem }()
					walk(p)
				}(subDir)
				atomic.AddInt64(dirsScanned, 1)
			} else {
				info, err := entry.Info()
				if err == nil {
					size := getActualFileSize(filepath.Join(dirPath, entry.Name()), info)
					localBytes += size
					localFiles++
				}
			}
		}

		if localBytes > 0 {
			atomic.AddInt64(&total, localBytes)
			atomic.AddInt64(bytesScanned, localBytes)
		}
		if localFiles > 0 {
			atomic.AddInt64(filesScanned, localFiles)
		}
	}

	walk(root)
	wg.Wait()

	return total
}

// Use Spotlight (mdfind) to quickly find large files.
func findLargeFilesWithSpotlight(root string, minSize int64) []fileEntry {
	query := fmt.Sprintf("kMDItemFSSize >= %d", minSize)

	ctx, cancel := context.WithTimeout(context.Background(), mdlsTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "mdfind", "-onlyin", root, query)
	output, err := cmd.Output()
	if err != nil {
		return nil
	}

	var files []fileEntry

	for line := range strings.Lines(strings.TrimSpace(string(output))) {
		if line == "" {
			continue
		}

		// Filter code files first (cheap).
		if shouldSkipFileForLargeTracking(line) {
			continue
		}

		// Filter folded directories (cheap string check).
		if isInFoldedDir(line) {
			continue
		}

		info, err := os.Lstat(line)
		if err != nil {
			continue
		}

		if info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			continue
		}

		// Actual disk usage for sparse/cloud files.
		actualSize := getActualFileSize(line, info)
		files = append(files, fileEntry{
			Name: filepath.Base(line),
			Path: line,
			Size: actualSize,
		})
	}

	// Sort by size (descending).
	sort.Slice(files, func(i, j int) bool {
		return files[i].Size > files[j].Size
	})

	if len(files) > maxLargeFiles {
		files = files[:maxLargeFiles]
	}

	return files
}

// isInFoldedDir checks if a path is inside a folded directory.
func isInFoldedDir(path string) bool {
	parts := strings.SplitSeq(path, string(os.PathSeparator))
	for part := range parts {
		if foldDirs[part] {
			return true
		}
	}
	return false
}

func calculateDirSizeConcurrent(root string, largeFileChan chan<- fileEntry, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) int64 {
	children, err := os.ReadDir(root)
	if err != nil {
		return 0
	}

	var total int64
	var wg sync.WaitGroup

	// Limit concurrent subdirectory scans.
	maxConcurrent := min(runtime.NumCPU()*2, maxDirWorkers)
	sem := make(chan struct{}, maxConcurrent)

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		if child.Type()&fs.ModeSymlink != 0 {
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			total += size
			atomic.AddInt64(filesScanned, 1)
			atomic.AddInt64(bytesScanned, size)
			continue
		}

		if child.IsDir() {
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				wg.Add(1)
				go func(path string) {
					defer wg.Done()
					size, err := getDirectorySizeFromDu(path)
					if err == nil && size > 0 {
						atomic.AddInt64(&total, size)
						atomic.AddInt64(bytesScanned, size)
						atomic.AddInt64(dirsScanned, 1)
					}
				}(fullPath)
				continue
			}

			wg.Add(1)
			go func(path string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				size := calculateDirSizeConcurrent(path, largeFileChan, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, size)
				atomic.AddInt64(dirsScanned, 1)
			}(fullPath)
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}

		size := getActualFileSize(fullPath, info)
		total += size
		atomic.AddInt64(filesScanned, 1)
		atomic.AddInt64(bytesScanned, size)

		if !shouldSkipFileForLargeTracking(fullPath) && size >= minLargeFileSize {
			largeFileChan <- fileEntry{Name: child.Name(), Path: fullPath, Size: size}
		}

		// Update current path occasionally to prevent UI jitter.
		if currentPath != nil && atomic.LoadInt64(filesScanned)%int64(batchUpdateSize) == 0 {
			*currentPath = fullPath
		}
	}

	wg.Wait()
	return total
}

// measureOverviewSize calculates the size of a directory using multiple strategies.
// When scanning Home, it excludes ~/Library to avoid duplicate counting.
func measureOverviewSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}

	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return 0, fmt.Errorf("path must be absolute: %s", path)
	}

	if _, err := os.Stat(path); err != nil {
		return 0, fmt.Errorf("cannot access path: %v", err)
	}

	// Determine if we should exclude ~/Library (when scanning Home)
	home := os.Getenv("HOME")
	excludePath := ""
	if home != "" && path == home {
		excludePath = filepath.Join(home, "Library")
	}

	if cached, err := loadStoredOverviewSize(path); err == nil && cached > 0 {
		return cached, nil
	}

	if duSize, err := getDirectorySizeFromDuWithExclude(path, excludePath); err == nil && duSize > 0 {
		_ = storeOverviewSize(path, duSize)
		return duSize, nil
	}

	if logicalSize, err := getDirectoryLogicalSizeWithExclude(path, excludePath); err == nil && logicalSize > 0 {
		_ = storeOverviewSize(path, logicalSize)
		return logicalSize, nil
	}

	if cached, err := loadCacheFromDisk(path); err == nil {
		_ = storeOverviewSize(path, cached.TotalSize)
		return cached.TotalSize, nil
	}

	return 0, fmt.Errorf("unable to measure directory size with fast methods")
}

func getDirectorySizeFromDu(path string) (int64, error) {
	return getDirectorySizeFromDuWithExclude(path, "")
}

func getDirectorySizeFromDuWithExclude(path string, excludePath string) (int64, error) {
	runDuSize := func(target string) (int64, error) {
		if _, err := os.Stat(target); err != nil {
			return 0, err
		}

		ctx, cancel := context.WithTimeout(context.Background(), duTimeout)
		defer cancel()

		cmd := exec.CommandContext(ctx, "du", "-sk", target)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		if err := cmd.Run(); err != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return 0, fmt.Errorf("du timeout after %v", duTimeout)
			}
			if stderr.Len() > 0 {
				return 0, fmt.Errorf("du failed: %v (%s)", err, stderr.String())
			}
			return 0, fmt.Errorf("du failed: %v", err)
		}
		fields := strings.Fields(stdout.String())
		if len(fields) == 0 {
			return 0, fmt.Errorf("du output empty")
		}
		kb, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil {
			return 0, fmt.Errorf("failed to parse du output: %v", err)
		}
		if kb <= 0 {
			return 0, fmt.Errorf("du size invalid: %d", kb)
		}
		return kb * 1024, nil
	}

	// When excluding a path (e.g., ~/Library), subtract only that exact directory instead of ignoring every "Library"
	if excludePath != "" {
		totalSize, err := runDuSize(path)
		if err != nil {
			return 0, err
		}
		excludeSize, err := runDuSize(excludePath)
		if err != nil {
			if !os.IsNotExist(err) {
				return 0, err
			}
			excludeSize = 0
		}
		if excludeSize > totalSize {
			excludeSize = 0
		}
		return totalSize - excludeSize, nil
	}

	return runDuSize(path)
}

func getDirectoryLogicalSizeWithExclude(path string, excludePath string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsPermission(err) {
				return filepath.SkipDir
			}
			return nil
		}
		// Skip excluded path
		if excludePath != "" && p == excludePath {
			return filepath.SkipDir
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		total += getActualFileSize(p, info)
		return nil
	})
	if err != nil && err != filepath.SkipDir {
		return 0, err
	}
	return total, nil
}

func getActualFileSize(_ string, info fs.FileInfo) int64 {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return info.Size()
	}

	actualSize := stat.Blocks * 512
	if actualSize < info.Size() {
		return actualSize
	}
	return info.Size()
}

func getLastAccessTime(path string) time.Time {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return getLastAccessTimeFromInfo(info)
}

func getLastAccessTimeFromInfo(info fs.FileInfo) time.Time {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return time.Time{}
	}
	return time.Unix(stat.Atimespec.Sec, stat.Atimespec.Nsec)
}
