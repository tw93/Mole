//go:build darwin

package main

import (
	"bytes"
	"container/heap"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"
)

var spotlightQueryRunner = func(ctx context.Context, root, query string) ([]byte, error) {
	return exec.CommandContext(ctx, "mdfind", "-onlyin", root, query).Output()
}

// scanFailures retains only the first failure, even for a large unreadable tree,
// plus the first transient one so a timeout is never masked by an earlier
// permission denial. Workers may record concurrently; callers read err() after
// joining those workers.
type scanFailures struct {
	once           sync.Once
	first          error
	transientOnce  sync.Once
	firstTransient error
}

// duBinary is the system du. The size probe passes BSD-only -I ignore patterns
// and parses BSD's "du: <path>: ..." errors, and a GNU coreutils du earlier in
// PATH rejects -I outright. A var only so tests can point it at a stub.
var duBinary = "/usr/bin/du"

var (
	// duTimeout bounds one du while a scan lists a folder, where a slow child
	// can fall back to a partial size without holding the listing up. It also
	// bounds an overview row in --json, which prints nothing until every row
	// lands and whose callers often have shorter tool timeouts of their own.
	duTimeout = 30 * time.Second
	// overviewDuTimeout bounds an overview row. It has no fallback after its
	// deadline and shows a spinner meanwhile, so a normal walk of a large
	// ~/Library must finish rather than read as unknown (#1956).
	overviewDuTimeout = 5 * time.Minute

	// activeDu counts running du children so quitting can wait for their kill.
	activeDu atomic.Int64
)

func (f *scanFailures) record(err error) {
	if err != nil {
		f.once.Do(func() { f.first = err })
		if isTransientFailure(err) {
			f.transientOnce.Do(func() { f.firstTransient = err })
		}
	}
}

func (f *scanFailures) err() error {
	if f.firstTransient != nil {
		return f.firstTransient
	}
	return f.first
}

// scanPublication gives cancellation a linearizable boundary with externally
// visible scan side effects. A publication either completes before cancel
// returns, or observes the canceled scan and is rejected.
type scanPublication struct {
	ctx           context.Context
	cancelContext context.CancelFunc

	mu        sync.Mutex
	canceling atomic.Bool
	canceled  bool
}

func newScanPublication(ctx context.Context, cancel context.CancelFunc) *scanPublication {
	return &scanPublication{ctx: ctx, cancelContext: cancel}
}

func (p *scanPublication) cancel() {
	p.canceling.Store(true)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.canceled {
		return
	}
	p.canceled = true
	if p.cancelContext != nil {
		p.cancelContext()
	}
}

func (p *scanPublication) commit(action func() error) error {
	if p.canceling.Load() {
		return context.Canceled
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.canceling.Load() || p.canceled {
		return context.Canceled
	}
	if err := p.ctx.Err(); err != nil {
		return err
	}
	return action()
}

func (p *scanPublication) finish(action func()) {
	p.canceling.Store(true)
	p.mu.Lock()
	defer p.mu.Unlock()
	p.canceled = true
	if p.cancelContext != nil {
		p.cancelContext()
	}
	action()
}

// scanLimiter bundles the concurrency budgets used by a single scan pass.
//
// There are four separate semaphores on purpose: each protects a different
// scarce resource. Collapsing two of them changes scaling behavior in ways
// that are easy to get wrong; see the per-field notes before adjusting.
type scanLimiter struct {
	// entrySem caps the number of in-flight top-level entry workers (one per
	// child of the root being scanned). Acquired with tryAcquireEntry so the
	// caller can fall back to inline scanning when the budget is saturated.
	entrySem chan struct{}

	// duSem caps how many `du` subprocesses execute concurrently. Tuned
	// low (NumCPU capped at 4) because each du process is itself heavily
	// I/O parallel and saturating the disk hurts wall-clock latency.
	duSem chan struct{}

	// duQueueSem caps how many goroutines are *queued* to run du.
	// Distinct from duSem so we don't spawn one goroutine per pending
	// directory and grow memory linearly with the input set; without
	// this bound, large home dirs allocate thousands of stacks waiting
	// on duSem. Sized at 2x duSem to keep the worker side warm without
	// unbounded queueing.
	duQueueSem chan struct{}

	// fastSem caps the workers used by the fallback fast-sizing path
	// when du is unavailable or rejected. Same scale as entrySem because
	// the fast path replaces a single du subprocess with one walker.
	fastSem chan struct{}

	// seen tracks (dev, ino) of hardlinked files counted so far in this
	// scan so a file with multiple links is counted once, matching `du`.
	seen sync.Map
}

func newScanLimiter(childCount int) *scanLimiter {
	if childCount <= 0 {
		childCount = maxWorkers
	}
	numWorkers := max(min(max(runtime.NumCPU()*cpuMultiplier, minWorkers), maxWorkers, childCount), 1)
	return &scanLimiter{
		entrySem:   make(chan struct{}, numWorkers),
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
func trySend[T any](ctx context.Context, ch chan<- T, item T, timeout time.Duration) bool {
	if ctx.Err() != nil {
		return false
	}
	if timeout <= 0 {
		select {
		case <-ctx.Done():
			return false
		case ch <- item:
			return true
		default:
			return false
		}
	}

	select {
	case <-ctx.Done():
		return false
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
	case <-ctx.Done():
		return false
	case ch <- item:
		return true
	case <-timer.C:
		return false
	}
}

func acquireScanPermit(ctx context.Context, sem chan struct{}) error {
	select {
	case sem <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func getDirectorySizeFromDuWithLimiter(ctx context.Context, path string, limiter *scanLimiter) (int64, error) {
	if err := acquireScanPermit(ctx, limiter.duSem); err != nil {
		return 0, err
	}
	defer func() { <-limiter.duSem }()
	return getDirectorySizeFromDu(ctx, path)
}

func scanPathConcurrent(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	return scanPathConcurrentWithOptions(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, true, maxEntries)
}

func scanPathConcurrentAllEntries(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	return scanPathConcurrentWithOptions(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, true, 0)
}

func scanPathConcurrentWithOptions(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, useSpotlight bool, entryLimit int) (scanResult, error) {
	return scanPathConcurrentWithLimiter(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, useSpotlight, entryLimit, nil, scanCacheReuse, newScanPublication(ctx, nil))
}

type scanCachePolicy uint8

const (
	scanCacheReuse scanCachePolicy = iota
	scanCacheBypass
)

func scanPathConcurrentWithLimiter(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, useSpotlight bool, entryLimit int, limiter *scanLimiter, cachePolicy scanCachePolicy, publication *scanPublication) (scanResult, error) {
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, err
	}
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}
	if limiter == nil {
		limiter = newScanLimiter(len(children))
	}

	var total int64
	var localFilesScanned int64
	var localBytesScanned int64
	var subtreeFilesScanned atomic.Int64
	var dedupedHardlink atomic.Bool
	var incomplete atomic.Bool
	var transient atomic.Bool
	noteFailure := func(err error) {
		incomplete.Store(true)
		if isTransientFailure(err) {
			transient.Store(true)
		}
	}
	// Child results arrive already classified: scanSubdirWithCache marks a
	// child whose own ReadDir failed, and nested scans carry their flag up.
	noteChildResult := func(result scanResult) {
		if result.State != scanComplete {
			incomplete.Store(true)
		}
		if result.transientFailure {
			transient.Store(true)
		}
	}

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
			} else if sizePathBefore(entry.Size, entry.Path, (*entriesHeap)[0].Size, (*entriesHeap)[0].Path) {
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
			} else if sizePathBefore(file.Size, file.Path, (*largeFilesHeap)[0].Size, (*largeFilesHeap)[0].Path) {
				heap.Pop(largeFilesHeap)
				heap.Push(largeFilesHeap, file)
				atomic.StoreInt64(&largeFileMinSize, (*largeFilesHeap)[0].Size)
			}
		}
	})

	isRootDir := root == "/"
	home := os.Getenv("HOME")
	isHomeDir := home != "" && root == home

scanChildren:
	for _, child := range children {
		if ctx.Err() != nil {
			break
		}
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
				noteFailure(err)
				continue
			}
			size := getActualFileSize(fullPath, info)
			atomic.AddInt64(&total, size)

			trySend(ctx, entryChan, dirEntry{
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
					if ctx.Err() != nil {
						return
					}
					result := scanResult{}
					if cachePolicy == scanCacheReuse {
						if cached, state, err := loadStoredOverviewMeasurement(path); err == nil && cached > 0 {
							result.TotalSize = cached
							result.State = state
						}
					}
					if result.TotalSize <= 0 {
						result = scanSubdirWithCache(ctx, path, largeFileChan, limiter, filesScanned, dirsScanned, bytesScanned, currentPath, cachePolicy, publication)
					}
					if ctx.Err() != nil {
						return
					}
					noteChildResult(result)
					atomic.AddInt64(&total, result.TotalSize)
					if result.TotalFiles > 0 {
						subtreeFilesScanned.Add(result.TotalFiles)
					}
					if result.dedupedHardlink {
						dedupedHardlink.Store(true)
					}
					atomic.AddInt64(dirsScanned, 1)

					trySend(ctx, entryChan, dirEntry{
						Name:       name,
						Path:       path,
						Size:       result.TotalSize,
						State:      result.State,
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
				if acquireScanPermit(ctx, duQueueSem) != nil {
					break scanChildren
				}
				wg.Go(func() {
					defer func() { <-duQueueSem }()
					if ctx.Err() != nil {
						return
					}

					size, err := getDirectorySizeFromDuWithLimiter(ctx, fullPath, limiter)
					if ctx.Err() != nil {
						return
					}
					if size <= 0 && err != nil {
						size, err = calculateDirSizeFastWithLimiter(ctx, fullPath, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					if ctx.Err() != nil {
						return
					}
					if err != nil {
						noteFailure(err)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					trySend(ctx, entryChan, dirEntry{
						Name:       child.Name(),
						Path:       fullPath,
						Size:       size,
						State:      measurementState(size, err),
						IsDir:      true,
						LastAccess: time.Time{},
					}, scanSendTimeout)
				})
				continue
			}

			processDir := func(name, path string) {
				if ctx.Err() != nil {
					return
				}
				result := scanSubdirWithCache(ctx, path, largeFileChan, limiter, filesScanned, dirsScanned, bytesScanned, currentPath, cachePolicy, publication)
				if ctx.Err() != nil {
					return
				}
				noteChildResult(result)
				atomic.AddInt64(&total, result.TotalSize)
				if result.TotalFiles > 0 {
					subtreeFilesScanned.Add(result.TotalFiles)
				}
				if result.dedupedHardlink {
					dedupedHardlink.Store(true)
				}
				atomic.AddInt64(dirsScanned, 1)

				trySend(ctx, entryChan, dirEntry{
					Name:       name,
					Path:       path,
					Size:       result.TotalSize,
					State:      result.State,
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
			noteFailure(err)
			continue
		}
		// Actual disk usage for sparse/cloud files, deduping hardlinks.
		size, deduped := countableFileSize(fullPath, info, &limiter.seen)
		if deduped {
			dedupedHardlink.Store(true)
		}
		atomic.AddInt64(&total, size)
		localFilesScanned++
		localBytesScanned += size

		trySend(ctx, entryChan, dirEntry{
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
				trySend(ctx, largeFileChan, fileEntry{Name: child.Name(), Path: fullPath, Size: size}, scanSendTimeout)
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
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}

	// Convert heaps to sorted slices (descending).
	var entries []dirEntry
	if collectAllEntries {
		entries = append(entries, collectedEntries...)
		sortDirEntriesBySize(entries)
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
		spotlightFiles, _ := findLargeFilesWithSpotlight(ctx, root, spotlightMinFileSize)
		if err := ctx.Err(); err != nil {
			return scanResult{}, err
		}
		if len(spotlightFiles) > len(largeFiles) {
			largeFiles = spotlightFiles
		}
	}
	sortFileEntriesBySize(largeFiles)

	state := scanComplete
	if incomplete.Load() {
		state = scanPartial
	}
	return scanResult{
		State:            state,
		Entries:          entries,
		LargeFiles:       largeFiles,
		TotalSize:        total,
		TotalFiles:       localFilesScanned + subtreeFilesScanned.Load(),
		dedupedHardlink:  dedupedHardlink.Load(),
		transientFailure: transient.Load(),
	}, nil
}

func publishLargeFiles(ctx context.Context, files []fileEntry, largeFileChan chan<- fileEntry) {
	for _, file := range files {
		if !trySend(ctx, largeFileChan, file, scanSendTimeout) && ctx.Err() != nil {
			return
		}
	}
}

func loadCachedSubdirResult(ctx context.Context, path string, largeFileChan chan<- fileEntry) (scanResult, bool) {
	if ctx.Err() != nil {
		return scanResult{}, false
	}
	cached, err := loadCacheFromDisk(path)
	if err != nil {
		return scanResult{}, false
	}

	result := scanResult{
		State:      cached.State,
		Entries:    cached.Entries,
		LargeFiles: cached.LargeFiles,
		TotalSize:  cached.TotalSize,
		TotalFiles: cached.TotalFiles,
	}
	publishLargeFiles(ctx, result.LargeFiles, largeFileChan)
	return result, true
}

func scanSubdirWithCache(ctx context.Context, root string, largeFileChan chan<- fileEntry, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, cachePolicy scanCachePolicy, publication *scanPublication) scanResult {
	if ctx.Err() != nil {
		return scanResult{}
	}
	if cachePolicy == scanCacheReuse {
		if cached, ok := loadCachedSubdirResult(ctx, root, largeFileChan); ok {
			if ctx.Err() != nil {
				return scanResult{}
			}
			if cached.TotalFiles > 0 {
				atomic.AddInt64(filesScanned, cached.TotalFiles)
			}
			if cached.TotalSize > 0 {
				atomic.AddInt64(bytesScanned, cached.TotalSize)
			}
			return cached
		}
	}

	result, err := scanPathConcurrentWithLimiter(ctx, root, filesScanned, dirsScanned, bytesScanned, currentPath, false, maxEntries, limiter, cachePolicy, publication)
	if err == nil {
		if ctx.Err() != nil {
			return scanResult{}
		}
		publishLargeFiles(ctx, result.LargeFiles, largeFileChan)
		if ctx.Err() != nil {
			return scanResult{}
		}
		// A subtree whose size depended on hardlink dedup is scan-order
		// dependent; caching it would poison standalone re-scans. Cheap
		// subtrees are not persisted at all: see shouldPersistSubdirCache.
		if !result.dedupedHardlink && shouldPersistSubdirCache(result) {
			_ = saveCacheToDiskWithOptions(publication, root, result, true)
		} else if cachePolicy == scanCacheBypass && result.persistable() {
			_ = removeCacheEntryForScan(publication, root)
		}
		return result
	}
	if ctx.Err() != nil {
		return scanResult{}
	}

	// Only the requested subtree failed; accessible siblings are scanned by
	// their own workers. Retrying the same ReadDir cannot recover its coverage.
	return scanResult{State: scanUnavailable, transientFailure: isTransientFailure(err)}
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
func calculateDirSizeFast(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (int64, error) {
	return calculateDirSizeFastWithLimiter(ctx, root, newScanLimiter(0), filesScanned, dirsScanned, bytesScanned, currentPath)
}

func calculateDirSizeFastWithLimiter(ctx context.Context, root string, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (int64, error) {
	var total atomic.Int64
	var wg sync.WaitGroup
	var failures scanFailures

	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
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
			failures.record(err)
			return
		}

		var localBytes, localFiles int64

		for _, entry := range entries {
			if ctx.Err() != nil {
				return
			}
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
				failures.record(err)
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

	failures.record(ctx.Err())
	return total.Load(), failures.err()
}

// Use Spotlight (mdfind) to quickly find large files.
func findLargeFilesWithSpotlight(ctx context.Context, root string, minSize int64) ([]fileEntry, error) {
	// Validate root path.
	if err := validatePath(root); err != nil {
		return nil, nil
	}

	// Validate minSize is reasonable (non-negative and not excessively large).
	if minSize < 0 || minSize > 1<<50 { // 1 PB max
		return nil, nil
	}

	query := fmt.Sprintf("kMDItemFSSize >= %d", minSize)

	ctx, cancel := context.WithTimeout(ctx, mdlsTimeout)
	defer cancel()

	output, err := spotlightQueryRunner(ctx, root, query)
	if err != nil {
		return nil, err
	}

	h := &largeFileHeap{}
	heap.Init(h)

	for line := range strings.Lines(strings.TrimSpace(string(output))) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
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
		} else if sizePathBefore(candidate.Size, candidate.Path, (*h)[0].Size, (*h)[0].Path) {
			heap.Pop(h)
			heap.Push(h, candidate)
		}
	}

	files := make([]fileEntry, h.Len())
	for i := range slices.Backward(files) {
		files[i] = heap.Pop(h).(fileEntry)
	}

	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return files, nil
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

// measureOverviewSize calculates the size of a directory using multiple strategies.
// When scanning Home, it excludes ~/Library to avoid duplicate counting.
func measureOverviewSize(ctx context.Context, path string) (int64, error) {
	return measureOverviewSizeWithPublication(ctx, path, nil)
}

func measureOverviewSizeWithPublication(ctx context.Context, path string, publication *scanPublication) (int64, error) {
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

	ctx, cancel := context.WithTimeout(ctx, overviewDuTimeout)
	defer cancel()
	ignoreNames := overviewIgnoreNamesForPath(path)
	size, err := getDirectorySizeFromDuWithExcludeAndIgnores(ctx, path, excludePath, ignoreNames, overviewDuTimeout)
	if err != nil && size == 0 && ctx.Err() == nil {
		size, err = getDirectoryLogicalSizeWithExclude(ctx, path, excludePath, ignoreNames)
	}
	if overviewMeasurementStorable(size, err) {
		store := func() error { return storeOverviewMeasurement(path, size, err != nil) }
		if publication != nil {
			if storeErr := publication.commit(store); errors.Is(storeErr, context.Canceled) || errors.Is(storeErr, context.DeadlineExceeded) {
				return 0, storeErr
			}
		} else {
			_ = store()
		}
	}
	return size, err
}

// overviewMeasurementStorable keeps a measurement whose only failures were
// permission denials, like a clean one: re-measuring cannot recover those
// bytes until access changes. Transient failures stay unstored.
func overviewMeasurementStorable(size int64, err error) bool {
	return size > 0 && (err == nil || isPermissionFailure(err))
}

func getDirectorySizeFromDu(ctx context.Context, path string) (int64, error) {
	return getDirectorySizeFromDuWithExclude(ctx, path, "")
}

func getDirectorySizeFromDuWithExclude(ctx context.Context, path string, excludePath string) (int64, error) {
	return getDirectorySizeFromDuWithExcludeAndIgnores(ctx, path, excludePath, nil, duTimeout)
}

// duError keeps a short diagnostic separate from paths and the process status.
// Unwrap preserves cancellation, permission and exit-status classification.
type duError struct {
	cause  error
	reason string
}

func (e *duError) Error() string {
	if e.reason == "" {
		return e.cause.Error()
	}
	return fmt.Sprintf("%v: %s", e.cause, e.reason)
}

func (e *duError) Unwrap() error { return e.cause }

func duDiagnosticReason(stderr []byte) string {
	for line := range strings.Lines(string(stderr)) {
		// BSD du prints "du: <path>: <strerror>". The last separator
		// avoids copying a path that itself contains colons and spaces.
		separator := strings.LastIndex(line, ": ")
		if !strings.HasPrefix(line, "du: ") || separator <= len("du") {
			continue
		}
		reason := strings.TrimSpace(strings.Map(func(r rune) rune {
			if unicode.IsControl(r) || unicode.IsSpace(r) {
				return ' '
			}
			return r
		}, line[separator+2:]))
		if reason != "" {
			return reason
		}
	}
	return ""
}

func getDirectorySizeFromDuWithExcludeAndIgnores(ctx context.Context, path string, excludePath string, ignoreNames []string, timeout time.Duration) (int64, error) {
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

		ctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()

		args := []string{"-skPx"}
		for _, ignoreName := range ignoreNames {
			args = append(args, "-I", ignoreName)
		}
		args = append(args, target)
		cmd := exec.CommandContext(ctx, duBinary, args...)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr

		activeDu.Add(1)
		runErr := cmd.Run()
		activeDu.Add(-1)
		fields := strings.Fields(stdout.String())
		if ctx.Err() != nil {
			runErr = ctx.Err()
		} else if runErr != nil && duReportedOnlyPermissionDenials(stderr.Bytes()) {
			// du exits 1 for any unreadable descendant; its stderr is the
			// only place that says whether every failure was a denial.
			runErr = fmt.Errorf("%w: %w", runErr, fs.ErrPermission)
		}
		if runErr != nil && ctx.Err() == nil {
			runErr = &duError{cause: runErr, reason: duDiagnosticReason(stderr.Bytes())}
		}
		if len(fields) == 0 {
			if runErr != nil {
				return 0, fmt.Errorf("du failed for %s: %w", target, runErr)
			}
			return 0, fmt.Errorf("du output empty for %s", target)
		}
		kb, parseErr := strconv.ParseInt(fields[0], 10, 64)
		if parseErr != nil {
			return 0, fmt.Errorf("failed to parse du output: %v", parseErr)
		}
		if kb < 0 {
			return 0, fmt.Errorf("du size invalid: %d", kb)
		}
		// Nonzero exits may still carry useful bytes for readable descendants.
		// Keep both the bytes and the failure; do not trigger another full walk.
		if runErr != nil {
			return kb * 1024, fmt.Errorf("du incomplete for %s: %w", target, runErr)
		}
		return kb * 1024, nil
	}

	// When excluding a path (e.g., ~/Library), subtract only that exact directory instead of ignoring every "Library"
	if excludePath != "" {
		if filepath.Dir(filepath.Clean(excludePath)) == filepath.Clean(path) {
			return getDirectorySizeFromDuSkippingImmediateChild(ctx, path, excludePath, runDuSize)
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

	// Library needs one traversal so cross-directory hardlinks count once.
	return runDuSize(path)
}

// duReportedOnlyPermissionDenials reports whether du's stderr holds at least
// one diagnostic and every one is a permission denial. macOS strerror text is
// not localized, so matching the suffix is stable.
func duReportedOnlyPermissionDenials(stderr []byte) bool {
	found := false
	for line := range strings.Lines(string(stderr)) {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if !strings.HasSuffix(line, ": Permission denied") && !strings.HasSuffix(line, ": Operation not permitted") {
			return false
		}
		found = true
	}
	return found
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

func getDirectorySizeFromDuSkippingImmediateChild(ctx context.Context, path string, excludePath string, runDuSize func(string) (int64, error)) (int64, error) {
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
	var failures scanFailures
	if info, err := os.Lstat(path); err == nil {
		atomic.AddInt64(&total, getActualFileSize(path, info))
	} else {
		failures.record(err)
	}

	var wg sync.WaitGroup
	workerCount := min(max(runtime.NumCPU()*2, 2), 8)
	sem := make(chan struct{}, workerCount)

	for _, entry := range entries {
		if ctx.Err() != nil {
			failures.record(ctx.Err())
			break
		}
		fullPath := filepath.Join(path, entry.Name())
		if filepath.Clean(fullPath) == excludePath {
			continue
		}

		if entry.Type()&fs.ModeSymlink != 0 || !entry.IsDir() {
			info, err := entry.Info()
			if err != nil {
				failures.record(err)
				continue
			}
			atomic.AddInt64(&total, getActualFileSize(fullPath, info))
			continue
		}

		if err := acquireScanPermit(ctx, sem); err != nil {
			failures.record(err)
			break
		}
		wg.Go(func() {
			defer func() { <-sem }()

			size, err := runDuSize(fullPath)
			failures.record(err)
			atomic.AddInt64(&total, size)
		})
	}

	wg.Wait()

	return total, failures.err()
}

func getDirectoryLogicalSizeWithExclude(ctx context.Context, path string, excludePath string, ignoreNames []string) (int64, error) {
	var total int64
	var failures scanFailures
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err != nil {
			failures.record(err)
			if d != nil && d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		// Skip excluded path
		if p == excludePath || (p != path && d.IsDir() && slices.Contains(ignoreNames, d.Name())) {
			return filepath.SkipDir
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			failures.record(err)
			return nil
		}
		total += getActualFileSize(p, info)
		return nil
	})
	failures.record(err)
	return total, failures.err()
}

// Clone IDs are volume-local and separate from inode identities.
type cloneKey struct {
	device uint32
	id     uint64
}

// countableFileSize returns the on-disk size to attribute to a regular file.
// Hardlinked files are deduplicated the way `du` does: the first link counts
// its full size and subsequent links seen in the same scan count zero. An APFS
// clone that still shares every block with another file is counted once per
// clone id the same way, because each clone reports its full allocated size
// (#1728: copied worktrees summed to 2.28 TB on a 994 GB disk); an edited clone
// owns blocks and counts in full, since macOS does not say how many it shares.
// The bool reports whether this call was a deduplicated (zero-counted) file.
// A nil seen map disables deduplication.
func countableFileSize(path string, info fs.FileInfo, seen *sync.Map) (int64, bool) {
	size := getActualFileSize("", info)
	if seen == nil {
		return size, false
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return size, false
	}
	if stat.Nlink > 1 {
		key := [2]uint64{uint64(uint32(stat.Dev)), stat.Ino}
		if _, loaded := seen.LoadOrStore(key, struct{}{}); loaded {
			return 0, true
		}
	}
	if size == 0 {
		return size, false
	}
	if cloneID, sharesAll, known := cloneIdentity(path); known && sharesAll {
		if _, loaded := seen.LoadOrStore(cloneKey{uint32(stat.Dev), cloneID}, struct{}{}); loaded {
			return 0, true
		}
	}
	return size, false
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
