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
	"slices"
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

type scanLimiter struct {
	entrySem   chan struct{}
	dirSem     chan struct{}
	duSem      chan struct{}
	duQueueSem chan struct{}
	fastSem    chan struct{}
}

func newScanLimiter(childCount int) *scanLimiter {
	if childCount <= 0 {
		childCount = maxWorkers
	}
	numWorkers := max(min(max(runtime.NumCPU()*cpuMultiplier, minWorkers), maxWorkers, childCount), 1)
	return &scanLimiter{
		entrySem:   make(chan struct{}, numWorkers),
		dirSem:     make(chan struct{}, min(runtime.NumCPU()*2, maxDirWorkers)),
		duSem:      make(chan struct{}, min(4, runtime.NumCPU())),
		duQueueSem: make(chan struct{}, min(4, runtime.NumCPU())*2),
		fastSem:    make(chan struct{}, min(runtime.NumCPU()*cpuMultiplier, maxWorkers)),
	}
}

func (l *scanLimiter) tryAcquireEntry() bool {
	if l == nil || l.entrySem == nil {
		return false
	}
	select {
	case l.entrySem <- struct{}{}:
		return true
	default:
		return false
	}
}

func (l *scanLimiter) releaseEntry() {
	if l != nil && l.entrySem != nil {
		<-l.entrySem
	}
}

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
	return scanPathConcurrentWithLimiter(root, filesScanned, dirsScanned, bytesScanned, currentPath, useSpotlight, entryLimit, nil)
}

func scanPathConcurrentWithLimiter(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, useSpotlight bool, entryLimit int, limiter *scanLimiter) (scanResult, error) {
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, err
	}
	if limiter == nil {
		limiter = newScanLimiter(len(children))
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

	dirSem := limiter.dirSem
	duSem := limiter.duSem
	duQueueSem := limiter.duQueueSem
	var wg sync.WaitGroup

	// Collect results via channels.
	// Cap buffer size to prevent memory spikes with huge directories.
	entryBufSize := max(min(len(children), 4096), 1)
	entryChan := make(chan dirEntry, entryBufSize)
	largeFileChan := make(chan fileEntry, maxLargeFiles*2)

	var collectorWg sync.WaitGroup
	collectorWg.Go(func() {
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
	})
	collectorWg.Go(func() {
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
	})

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
			}, scanSendTimeout)
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
				processDir := func(name, path string) {
					result := scanResult{}
					if cached, err := loadStoredOverviewSize(path); err == nil && cached > 0 {
						result.TotalSize = cached
					} else {
						result = scanSubdirWithCache(path, largeFileChan, &largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
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
					}, scanSendTimeout)
				}
				if limiter.tryAcquireEntry() {
					wg.Go(func() {
						defer limiter.releaseEntry()
						processDir(child.Name(), fullPath)
					})
				} else {
					processDir(child.Name(), fullPath)
				}
				continue
			}

			// Folded dirs: fast size without expanding.
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				duQueueSem <- struct{}{}
				wg.Go(func() {
					defer func() { <-duQueueSem }()

					size, err := func() (int64, error) {
						duSem <- struct{}{}
						defer func() { <-duSem }()
						return getDirectorySizeFromDu(fullPath)
					}()
					if err != nil || size <= 0 {
						size = calculateDirSizeFastWithLimiter(fullPath, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					trySend(entryChan, dirEntry{
						Name:       child.Name(),
						Path:       fullPath,
						Size:       size,
						IsDir:      true,
						LastAccess: time.Time{},
					}, scanSendTimeout)
				})
				continue
			}

			processDir := func(name, path string) {
				result := scanSubdirWithCache(path, largeFileChan, &largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
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
				}, scanSendTimeout)
			}
			if limiter.tryAcquireEntry() {
				wg.Go(func() {
					defer limiter.releaseEntry()
					processDir(child.Name(), fullPath)
				})
			} else {
				processDir(child.Name(), fullPath)
			}
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
		}, scanSendTimeout)

		// Track large files only.
		if !shouldSkipFileForLargeTracking(fullPath) {
			minSize := atomic.LoadInt64(&largeFileMinSize)
			if size >= minSize {
				trySend(largeFileChan, fileEntry{Name: child.Name(), Path: fullPath, Size: size}, scanSendTimeout)
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
		for i := range slices.Backward(entries) {
			entries[i] = heap.Pop(entriesHeap).(dirEntry)
		}
	}

	largeFiles := make([]fileEntry, largeFilesHeap.Len())
	for i := range slices.Backward(largeFiles) {
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
		trySend(largeFileChan, file, scanSendTimeout)
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

func scanSubdirWithCache(root string, largeFileChan chan<- fileEntry, largeFileMinSize *int64, limiter *scanLimiter, dirSem, duSem, duQueueSem chan struct{}, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) scanResult {
	if cached, ok := loadCachedSubdirResult(root, largeFileChan); ok {
		if cached.TotalFiles > 0 {
			atomic.AddInt64(filesScanned, cached.TotalFiles)
		}
		if cached.TotalSize > 0 {
			atomic.AddInt64(bytesScanned, cached.TotalSize)
		}
		return cached
	}

	result, err := scanPathConcurrentWithLimiter(root, filesScanned, dirsScanned, bytesScanned, currentPath, false, maxEntries, limiter)
	if err == nil {
		publishLargeFiles(result.LargeFiles, largeFileChan)
		_ = saveCacheToDiskWithOptions(root, result, true)
		return result
	}

	return scanResult{TotalSize: calculateDirSizeConcurrent(root, largeFileChan, largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)}
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
	return calculateDirSizeFastWithLimiter(root, newScanLimiter(0), filesScanned, dirsScanned, bytesScanned, currentPath)
}

func calculateDirSizeFastWithLimiter(root string, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) int64 {
	var total atomic.Int64
	var wg sync.WaitGroup

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	concurrency := min(runtime.NumCPU()*cpuMultiplier, maxWorkers)
	sem := make(chan struct{}, concurrency)
	if limiter != nil && limiter.fastSem != nil {
		sem = limiter.fastSem
	}

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
					wg.Go(func() {
						defer func() { <-sem }()
						walk(subDir)
					})
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
			total.Add(localBytes)
			atomic.AddInt64(bytesScanned, localBytes)
		}
		if localFiles > 0 {
			atomic.AddInt64(filesScanned, localFiles)
		}
	}

	walk(root)
	wg.Wait()

	return total.Load()
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
	for i := range slices.Backward(files) {
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

func calculateDirSizeConcurrent(root string, largeFileChan chan<- fileEntry, largeFileMinSize *int64, limiter *scanLimiter, dirSem, duSem, duQueueSem chan struct{}, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) int64 {
	children, err := os.ReadDir(root)
	if err != nil {
		return 0
	}

	var total atomic.Int64
	var localTotal int64
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
			localTotal += size
			localFilesScanned++
			localBytesScanned += size
			continue
		}

		if child.IsDir() {
			localDirsScanned++

			if shouldFoldDirWithPath(child.Name(), fullPath) {
				duQueueSem <- struct{}{}
				wg.Go(func() {
					defer func() { <-duQueueSem }()

					size, err := func() (int64, error) {
						duSem <- struct{}{}
						defer func() { <-duSem }()
						return getDirectorySizeFromDu(fullPath)
					}()
					if err != nil || size <= 0 {
						size = calculateDirSizeFastWithLimiter(fullPath, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
					} else {
						atomic.AddInt64(bytesScanned, size)
					}
					total.Add(size)
				})
				continue
			}

			select {
			case dirSem <- struct{}{}:
				wg.Go(func() {
					defer func() { <-dirSem }()

					size := calculateDirSizeConcurrent(fullPath, largeFileChan, largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
					total.Add(size)
				})
			default:
				size := calculateDirSizeConcurrent(fullPath, largeFileChan, largeFileMinSize, limiter, dirSem, duSem, duQueueSem, filesScanned, dirsScanned, bytesScanned, currentPath)
				localTotal += size
			}
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}

		size := getActualFileSize(fullPath, info)
		localTotal += size
		localFilesScanned++
		localBytesScanned += size

		if !shouldSkipFileForLargeTracking(fullPath) && largeFileMinSize != nil {
			minSize := atomic.LoadInt64(largeFileMinSize)
			if size >= minSize {
				trySend(largeFileChan, fileEntry{Name: child.Name(), Path: fullPath, Size: size}, scanSendTimeout)
			}
		}

		// Update current path occasionally to prevent UI jitter.
		if currentPath != nil && localFilesScanned%int64(batchUpdateSize) == 0 {
			currentPath.Store(fullPath)
		}
	}

	if localTotal > 0 {
		total.Add(localTotal)
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

	return total.Load()
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

	if duSize, err := getDirectorySizeFromDuWithExcludeAndIgnores(path, excludePath, overviewIgnoreNamesForPath(path)); err == nil {
		_ = storeOverviewSize(path, duSize)
		return duSize, nil
	}

	if logicalSize, err := getDirectoryLogicalSizeWithExclude(path, excludePath); err == nil {
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
	return getDirectorySizeFromDuWithExcludeAndIgnores(path, excludePath, nil)
}

func getDirectorySizeFromDuWithExcludeAndIgnores(path string, excludePath string, ignoreNames []string) (int64, error) {
	// Validate paths.
	if err := validatePath(path); err != nil {
		return 0, err
	}
	if excludePath != "" {
		if err := validatePath(excludePath); err != nil {
			return 0, err
		}
	}
	for _, ignoreName := range ignoreNames {
		if err := validateDuIgnoreName(ignoreName); err != nil {
			return 0, err
		}
	}

	runDuSize := func(target string) (int64, error) {
		if _, err := os.Stat(target); err != nil {
			return 0, err
		}

		ctx, cancel := context.WithTimeout(context.Background(), duTimeout)
		defer cancel()

		args := []string{"-skPx"}
		for _, ignoreName := range ignoreNames {
			args = append(args, "-I", ignoreName)
		}
		args = append(args, target)
		cmd := exec.CommandContext(ctx, "du", args...)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		runErr := cmd.Run()
		fields := strings.Fields(stdout.String())
		if runErr != nil {
			if ctx.Err() == context.DeadlineExceeded {
				return 0, fmt.Errorf("du timeout after %v", duTimeout)
			}
			// BSD du may return non-zero for unreadable descendants while still
			// printing a useful aggregate for the requested root. Use that best
			// effort total instead of falling back to a much slower recursive walk.
			if len(fields) == 0 {
				if stderr.Len() > 0 {
					return 0, fmt.Errorf("du failed: %v, %s", runErr, stderr.String())
				}
				return 0, fmt.Errorf("du failed: %v", runErr)
			}
		}
		if len(fields) == 0 {
			return 0, fmt.Errorf("du output empty")
		}
		kb, parseErr := strconv.ParseInt(fields[0], 10, 64)
		if parseErr != nil {
			return 0, fmt.Errorf("failed to parse du output: %v", parseErr)
		}
		if kb <= 0 {
			if runErr != nil {
				return 0, fmt.Errorf("du failed: %v", runErr)
			}
			return 0, fmt.Errorf("du size invalid: %d", kb)
		}
		return kb * 1024, nil
	}

	// When excluding a path (e.g., ~/Library), subtract only that exact directory instead of ignoring every "Library"
	if excludePath != "" {
		if size, err := getDirectorySizeFromDuSkippingImmediateChild(path, excludePath, runDuSize); err == nil {
			return size, nil
		}

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

func validateDuIgnoreName(name string) error {
	if name == "" {
		return fmt.Errorf("empty du ignore name")
	}
	if strings.Contains(name, "\x00") {
		return fmt.Errorf("du ignore name contains null bytes")
	}
	if strings.ContainsAny(name, `/\`) {
		return fmt.Errorf("du ignore name must be a basename: %s", name)
	}
	return nil
}

func overviewIgnoreNamesForPath(path string) []string {
	entries, err := os.ReadDir(path)
	if err != nil {
		return nil
	}

	ignoreNames := make([]string, 0, len(overviewDuIgnoreNames))
	for _, entry := range entries {
		name := entry.Name()
		if overviewDuIgnoreNames[name] && entry.IsDir() {
			ignoreNames = append(ignoreNames, name)
		}
	}
	return ignoreNames
}

func getDirectorySizeFromDuSkippingImmediateChild(path string, excludePath string, runDuSize func(string) (int64, error)) (int64, error) {
	path = filepath.Clean(path)
	excludePath = filepath.Clean(excludePath)

	rel, err := filepath.Rel(path, excludePath)
	if err != nil {
		return 0, err
	}
	if rel == "." || rel == ".." || filepath.IsAbs(rel) || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return 0, fmt.Errorf("exclude path is outside base: %s", excludePath)
	}
	if strings.Contains(rel, string(os.PathSeparator)) {
		return 0, fmt.Errorf("exclude path is not an immediate child: %s", excludePath)
	}

	entries, err := os.ReadDir(path)
	if err != nil {
		return 0, err
	}

	var total int64
	if info, err := os.Lstat(path); err == nil {
		atomic.AddInt64(&total, getActualFileSize(path, info))
	}

	var wg sync.WaitGroup
	var firstErr error
	var errMu sync.Mutex
	workerCount := min(max(runtime.NumCPU()*2, 2), 8)
	sem := make(chan struct{}, workerCount)

	recordErr := func(err error) {
		if err == nil {
			return
		}
		errMu.Lock()
		defer errMu.Unlock()
		if firstErr == nil {
			firstErr = err
		}
	}

	for _, entry := range entries {
		fullPath := filepath.Join(path, entry.Name())
		if filepath.Clean(fullPath) == excludePath {
			continue
		}

		if entry.Type()&fs.ModeSymlink != 0 || !entry.IsDir() {
			info, err := entry.Info()
			if err != nil {
				continue
			}
			atomic.AddInt64(&total, getActualFileSize(fullPath, info))
			continue
		}

		sem <- struct{}{}
		wg.Go(func() {
			defer func() { <-sem }()

			size, err := runDuSize(fullPath)
			if err != nil {
				recordErr(err)
				return
			}
			atomic.AddInt64(&total, size)
		})
	}

	wg.Wait()

	if firstErr != nil {
		return 0, firstErr
	}
	return total, nil
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
