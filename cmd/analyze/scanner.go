//go:build darwin

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

// trySend attempts to send an item to a channel with a timeout.
// Returns true if the item was sent, false if the timeout was reached.
func trySend[T any](ch chan<- T, item T, timeout time.Duration) bool {
	if timeout <= 0 {
		select {
		case ch <- item:
			return true
		default:
			return false
		}
	}

	select {
	case ch <- item:
		return true
	default:
	}

	timer := time.NewTimer(timeout)
	defer func() {
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
	}()

	select {
	case ch <- item:
		return true
	case <-timer.C:
		return false
	}
}

func scanPathConcurrent(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	return scanPathConcurrentWithOptions(root, filesScanned, dirsScanned, bytesScanned, currentPath, true, maxEntries)
}

func scanPathConcurrentAllEntries(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	return scanPathConcurrentWithOptions(root, filesScanned, dirsScanned, bytesScanned, currentPath, true, 0)
}

func scanPathConcurrentWithOptions(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, useSpotlight bool, entryLimit int) (scanResult, error) {
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, err
	}

	var total int64
	var localFilesScanned int64
	var localBytesScanned int64
	var subtreeFilesScanned atomic.Int64

	collectAllEntries := entryLimit <= 0
	var collectedEntries []dirEntry

	// Keep Top N heaps when a limit is requested.
	entriesHeap := &entryHeap{}
	if !collectAllEntries {
		heap.Init(entriesHeap)
	}

	largeFilesHeap := &largeFileHeap{}
	heap.Init(largeFilesHeap)
	largeFileMinSize := int64(largeFileWarmupMinSize)

	// Worker pool sized for I/O-bound scanning.
	numWorkers := max(min(max(runtime.NumCPU()*cpuMultiplier, minWorkers), maxWorkers, len(children)), 1)
	sem := make(chan struct{}, numWorkers)
	dirSem := make(chan struct{}, min(runtime.NumCPU()*2, maxDirWorkers))
	duSem := make(chan struct{}, min(4, runtime.NumCPU()))        // limits concurrent du processes
	duQueueSem := make(chan struct{}, min(4, runtime.NumCPU())*2) // limits how many goroutines may be waiting to run du
	var wg sync.WaitGroup

	// Collect results via channels.
	// Cap buffer size to prevent memory spikes with huge directories.
	entryBufSize := max(min(len(children), 4096), 1)
	entryChan := make(chan dirEntry, entryBufSize)
	largeFileChan := make(chan fileEntry, maxLargeFiles*2)

	var collectorWg sync.WaitGroup
	collectorWg.Add(2)
	go func() {
		defer collectorWg.Done()
		for entry := range entryChan {
			if collectAllEntries {
				collectedEntries = append(collectedEntries, entry)
				continue
			}

			if entriesHeap.Len() < entryLimit {
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
				if largeFilesHeap.Len() == maxLargeFiles {
					atomic.StoreInt64(&largeFileMinSize, (*largeFilesHeap)[0].Size)
				}
			} else if file.Size > (*largeFilesHeap)[0].Size {
				heap.Pop(largeFilesHeap)
				heap.Push(largeFilesHeap, file)
				atomic.StoreInt64(&largeFileMinSize, (*largeFilesHeap)[0].Size)
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

			trySend(entryChan, dirEntry{
				Name:       child.Name() + " →",
				Path:       fullPath,
				Size:       size,
				IsDir:      isDir,
				LastAccess: getLastAccessTimeFromInfo(info),
			}, 100*time.Millisecond)
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
				sem <- struct{}{}
				wg.Add(1)
				go func(name, path string) {
					defer wg.Done()
					defer func() { <-sem }()

					result := scanResult{}
					if cached, err := loadStoredOverviewSize(path); err == nil && cached > 0 {
						result.TotalSize = cached
					} else {
						result = scanSubdirWithCache(path, largeFileChan, &largeFileMinSize, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, result.TotalSize)
					if result.TotalFiles > 0 {
						subtreeFilesScanned.Add(result.TotalFiles)
					}
					atomic.AddInt64(dirsScanned, 1)

					trySend(entryChan, dirEntry{
						Name:       name,
						Path:       path,
						Size:       result.TotalSize,
						IsDir:      true,
						LastAccess: time.Time{},
					}, 100*time.Millisecond)
				}(child.Name(), fullPath)
				continue
			}

			// Folded dirs: fast size without expanding.
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				duQueueSem <- struct{}{}
				wg.Add(1)
				go func(name, path string) {
					defer wg.Done()
					defer func() { <-duQueueSem }()

					size, err := func() (int64, error) {
						duSem <- struct{}{}
						defer func() { <-duSem }()
						return getDirectorySizeFromDu(path)
					}()
					if err != nil || size <= 0 {
						size = calculateDirSizeFast(path, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					trySend(entryChan, dirEntry{
						Name:       name,
						Path:       path,
						Size:       size,
						IsDir:      true,
						LastAccess: time.Time{},
					}, 100*time.Millisecond)
				}(child.Name(), fullPath)
				continue
			}

			sem <- struct{}{}
			wg.Add(1)
			go func(name, path string) {
				defer wg.Done()
				defer func() { <-sem }()

				result := scanSubdirWithCache(path, largeFileChan, &largeFileMinSize, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, result.TotalSize)
				if result.TotalFiles > 0 {
					subtreeFilesScanned.Add(result.TotalFiles)
				}
				atomic.AddInt64(dirsScanned, 1)

				trySend(entryChan, dirEntry{
					Name:       name,
					Path:       path,
					Size:       result.TotalSize,
					IsDir:      true,
					LastAccess: time.Time{},
				}, 100*time.Millisecond)
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
		localFilesScanned++
		localBytesScanned += size

		trySend(entryChan, dirEntry{
			Name:       child.Name(),
			Path:       fullPath,
			Size:       size,
			IsDir:      false,
			LastAccess: getLastAccessTimeFromInfo(info),
		}, 100*time.Millisecond)

		// Track large files only.
		if !shouldSkipFileForLargeTracking(fullPath) {
			minSize := atomic.LoadInt64(&largeFileMinSize)
			if size >= minSize {
				trySend(largeFileChan, fileEntry{Name: child.Name(), Path: fullPath, Size: size}, 100*time.Millisecond)
			}
		}
	}

	if localFilesScanned > 0 {
		atomic.AddInt64(filesScanned, localFilesScanned)
	}
	if localBytesScanned > 0 {
		atomic.AddInt64(bytesScanned, localBytesScanned)
	}

	wg.Wait()

	// Close channels and wait for collectors.
	close(entryChan)
	close(largeFileChan)
	collectorWg.Wait()

	// Convert heaps to sorted slices (descending).
	var entries []dirEntry
	if collectAllEntries {
		entries = append(entries, collectedEntries...)
		sort.SliceStable(entries, func(i, j int) bool {
			return entries[i].Size > entries[j].Size
		})
	} else {
		entries = make([]dirEntry, entriesHeap.Len())
		for i := len(entries) - 1; i >= 0; i-- {
			entries[i] = heap.Pop(entriesHeap).(dirEntry)
		}
	}

	largeFiles := make([]fileEntry, largeFilesHeap.Len())
	for i := len(largeFiles) - 1; i >= 0; i-- {
		largeFiles[i] = heap.Pop(largeFilesHeap).(fileEntry)
	}

	// Use Spotlight for large files when it expands the list.
	if useSpotlight {
		if spotlightFiles := findLargeFilesWithSpotlight(root, spotlightMinFileSize); len(spotlightFiles) > len(largeFiles) {
			largeFiles = spotlightFiles
		}
	}

	return scanResult{
		Entries:    entries,
		LargeFiles: largeFiles,
		TotalSize:  total,
		TotalFiles: localFilesScanned + subtreeFilesScanned.Load(),
	}, nil
}

func publishLargeFiles(files []fileEntry, largeFileChan chan<- fileEntry) {
	for _, file := range files {
		trySend(largeFileChan, file, 100*time.Millisecond)
	}
}

func loadCachedSubdirResult(path string, largeFileChan chan<- fileEntry) (scanResult, bool) {
	cached, err := loadCacheFromDisk(path)
	if err != nil {
		return scanResult{}, false
	}

	result := scanResult{
		Entries:    cached.Entries,
		LargeFiles: cached.LargeFiles,
		TotalSize:  cached.TotalSize,
		TotalFiles: cached.TotalFiles,
	}
	publishLargeFiles(result.LargeFiles, largeFileChan)
	return result, true
}

func scanSubdirWithCache(root string, largeFileChan chan<- fileEntry, largeFileMinSize *int64, dirSem, duSem, duQueueSem chan struct{}, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) scanResult {
	if cached, ok := loadCachedSubdirResult(root, largeFileChan); ok {
		if cached.TotalFiles > 0 {
			atomic.AddInt64(filesScanned, cached.TotalFiles)
		}
		if cached.TotalSize > 0 {
			atomic.AddInt64(bytesScanned, cached.TotalSize)
		}
		return cached
	}

	result, err := scanPathConcurrentWithOptions(root, filesScanned, dirsScanned, bytesScanned, currentPath, false, maxEntries)
	if err == nil {
		publishLargeFiles(result.LargeFiles, largeFileChan)
		_ = saveCacheToDiskWithOptions(root, result, true)
		return result
	}

	return scanResult{TotalSize: calculateDirSizeConcurrent(root, largeFileChan, largeFileMinSize, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)}
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
func calculateDirSizeFast(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) int64 {
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
			currentPath.Store(dirPath)
		}

		entries, err := os.ReadDir(dirPath)
		if err != nil {
			return
		}

		var localBytes, localFiles int64

		for _, entry := range entries {
			if entry.IsDir() {
				subDir := filepath.Join(dirPath, entry.Name())
				atomic.AddInt64(dirsScanned, 1)

				select {
				case sem <- struct{}{}:
					wg.Add(1)
					go func(p string) {
						defer wg.Done()
						defer func() { <-sem }()
						walk(p)
					}(subDir)
				default:
					// Fallback to synchronous traversal to avoid semaphore deadlock under high fan-out.
					walk(subDir)
				}
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
	// Validate root path.
	if err := validatePath(root); err != nil {
		return nil
	}

	// Validate minSize is reasonable (non-negative and not excessively large).
	if minSize < 0 || minSize > 1<<50 { // 1 PB max
		return nil
	}

	query := fmt.Sprintf("kMDItemFSSize >= %d", minSize)

	ctx, cancel := context.WithTimeout(context.Background(), mdlsTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "mdfind", "-onlyin", root, query)
	output, err := cmd.Output()
	if err != nil {
		return nil
	}

	h := &largeFileHeap{}
	heap.Init(h)

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
		candidate := fileEntry{
			Name: filepath.Base(line),
			Path: line,
			Size: actualSize,
		}

		if h.Len() < maxLargeFiles {
			heap.Push(h, candidate)
		} else if candidate.Size > (*h)[0].Size {
			heap.Pop(h)
			heap.Push(h, candidate)
		}
	}

	files := make([]fileEntry, h.Len())
	for i := len(files) - 1; i >= 0; i-- {
		files[i] = heap.Pop(h).(fileEntry)
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

func calculateDirSizeConcurrent(root string, largeFileChan chan<- fileEntry, largeFileMinSize *int64, dirSem, duSem, duQueueSem chan struct{}, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) int64 {
	children, err := os.ReadDir(root)
	if err != nil {
		return 0
	}

	var total int64
	var localFilesScanned int64
	var localDirsScanned int64
	var localBytesScanned int64
	var wg sync.WaitGroup

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		if child.Type()&fs.ModeSymlink != 0 {
			info, err := child.Info()
			if err != nil {
				continue
			}
			size := getActualFileSize(fullPath, info)
			total += size
			localFilesScanned++
			localBytesScanned += size
			continue
		}

		if child.IsDir() {
			localDirsScanned++

			if shouldFoldDirWithPath(child.Name(), fullPath) {
				duQueueSem <- struct{}{}
				wg.Add(1)
				go func(path string) {
					defer wg.Done()
					defer func() { <-duQueueSem }()

					size, err := func() (int64, error) {
						duSem <- struct{}{}
						defer func() { <-duSem }()
						return getDirectorySizeFromDu(path)
					}()
					if err != nil || size <= 0 {
						size = calculateDirSizeFast(path, filesScanned, dirsScanned, bytesScanned, currentPath)
					} else {
						atomic.AddInt64(bytesScanned, size)
					}
					atomic.AddInt64(&total, size)
				}(fullPath)
				continue
			}

			select {
			case dirSem <- struct{}{}:
				wg.Add(1)
				go func(path string) {
					defer wg.Done()
					defer func() { <-dirSem }()

					size := calculateDirSizeConcurrent(path, largeFileChan, largeFileMinSize, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
					atomic.AddInt64(&total, size)
				}(fullPath)
			default:
				size := calculateDirSizeConcurrent(fullPath, largeFileChan, largeFileMinSize, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, size)
			}
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}

		size := getActualFileSize(fullPath, info)
		total += size
		localFilesScanned++
		localBytesScanned += size

		if !shouldSkipFileForLargeTracking(fullPath) && largeFileMinSize != nil {
			minSize := atomic.LoadInt64(largeFileMinSize)
			if size >= minSize {
				trySend(largeFileChan, fileEntry{Name: child.Name(), Path: fullPath, Size: size}, 100*time.Millisecond)
			}
		}

		// Update current path occasionally to prevent UI jitter.
		if currentPath != nil && localFilesScanned%int64(batchUpdateSize) == 0 {
			currentPath.Store(fullPath)
		}
	}

	wg.Wait()

	if localFilesScanned > 0 {
		atomic.AddInt64(filesScanned, localFilesScanned)
	}
	if localBytesScanned > 0 {
		atomic.AddInt64(bytesScanned, localBytesScanned)
	}
	if localDirsScanned > 0 {
		atomic.AddInt64(dirsScanned, localDirsScanned)
	}

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
	// Validate paths.
	if err := validatePath(path); err != nil {
		return 0, err
	}
	if excludePath != "" {
		if err := validatePath(excludePath); err != nil {
			return 0, err
		}
	}

	runDuSize := func(target string) (int64, error) {
		if _, err := os.Stat(target); err != nil {
			return 0, err
		}

		ctx, cancel := context.WithTimeout(context.Background(), duTimeout)
		defer cancel()

		cmd := exec.CommandContext(ctx, "du", "-skP", target)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		if err := cmd.Run(); err != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return 0, fmt.Errorf("du timeout after %v", duTimeout)
			}
			if stderr.Len() > 0 {
				return 0, fmt.Errorf("du failed: %v, %s", err, stderr.String())
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

func getLastAccessTimeFromInfo(info fs.FileInfo) time.Time {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return time.Time{}
	}
	return time.Unix(stat.Atimespec.Sec, stat.Atimespec.Nsec)
}
