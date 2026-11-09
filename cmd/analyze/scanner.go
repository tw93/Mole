package main

import (
	"container/heap"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// scanFailures retains only the first failure, plus the first transient one so
// a timeout is never masked by an earlier permission denial. Workers may record
// concurrently; callers read err() after joining those workers.
type scanFailures struct {
	once           sync.Once
	first          error
	transientOnce  sync.Once
	firstTransient error
}

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
// entrySem caps in-flight top-level entry workers and is acquired with
// tryAcquireEntry so the caller can scan inline when the budget is used up.
// walkSem caps the extra goroutines a directory walk may start.
type scanLimiter struct {
	entrySem chan struct{}
	walkSem  chan struct{}
}

func newScanLimiter(childCount int) *scanLimiter {
	if childCount <= 0 {
		childCount = maxWorkers
	}
	numWorkers := max(min(max(runtime.NumCPU()*cpuMultiplier, minWorkers), maxWorkers, childCount), 1)
	return &scanLimiter{
		entrySem: make(chan struct{}, numWorkers),
		walkSem:  make(chan struct{}, min(runtime.NumCPU()*cpuMultiplier, maxWorkers)),
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
	select {
	case <-ctx.Done():
		return false
	case ch <- item:
		return true
	default:
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return false
	case ch <- item:
		return true
	case <-timer.C:
		return false
	}
}

// isVolumeRoot reports whether path is the root of a drive or share, such as
// C:\, where the system folders in skipSystemDirs live.
func isVolumeRoot(path string) bool {
	clean := filepath.Clean(path)
	return filepath.Dir(clean) == clean
}

// scanPathConcurrent measures root's immediate children and returns the
// largest maxEntries of them plus the largest files found below root.
// Directory links (junctions, symbolic links) are listed but never followed.
func scanPathConcurrent(ctx context.Context, root string, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	return scanPathConcurrentWithLimit(ctx, root, maxEntries, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
}

// scanPathConcurrentAllEntries is scanPathConcurrent without the entry cap,
// for the JSON output, which lists every immediate child of root.
func scanPathConcurrentAllEntries(ctx context.Context, root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	return scanPathConcurrentWithLimit(ctx, root, 0, nil, filesScanned, dirsScanned, bytesScanned, currentPath)
}

// scanPathConcurrentWithLimit keeps the largest entryLimit children, or every
// child when entryLimit is zero or less.
func scanPathConcurrentWithLimit(ctx context.Context, root string, entryLimit int, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (scanResult, error) {
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}
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
	var incomplete atomic.Bool
	var transient atomic.Bool
	noteFailure := func(err error) {
		incomplete.Store(true)
		if isTransientFailure(err) {
			transient.Store(true)
		}
	}
	noteChildResult := func(result scanResult) {
		if result.State != scanComplete {
			incomplete.Store(true)
		}
		if result.transientFailure {
			transient.Store(true)
		}
	}

	collectAllEntries := entryLimit <= 0
	var allEntries []dirEntry
	entriesHeap := &entryHeap{}
	heap.Init(entriesHeap)
	largeFilesHeap := &largeFileHeap{}
	heap.Init(largeFilesHeap)
	largeFileMinSize := int64(largeFileWarmupMinSize)

	var wg sync.WaitGroup
	entryChan := make(chan dirEntry, max(min(len(children), 4096), 1))
	largeFileChan := make(chan fileEntry, maxLargeFiles*2)

	var collectorWg sync.WaitGroup
	collectorWg.Add(2)
	go func() {
		defer collectorWg.Done()
		for entry := range entryChan {
			if collectAllEntries {
				allEntries = append(allEntries, entry)
			} else if entriesHeap.Len() < entryLimit {
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

	atVolumeRoot := isVolumeRoot(root)

	for _, child := range children {
		if ctx.Err() != nil {
			break
		}
		fullPath := filepath.Join(root, child.Name())

		if isLinkEntry(child) {
			info, err := child.Info()
			if err != nil {
				noteFailure(err)
				continue
			}
			size := info.Size()
			atomic.AddInt64(&total, size)
			trySend(ctx, entryChan, dirEntry{
				Name:       child.Name() + " →",
				Path:       fullPath,
				Size:       size,
				LastAccess: lastAccessTime(info),
			}, scanSendTimeout)
			continue
		}

		if child.IsDir() {
			if atVolumeRoot && skipSystemDirs[child.Name()] {
				continue
			}
			name := child.Name()
			processDir := func() {
				if ctx.Err() != nil {
					return
				}
				var result scanResult
				if shouldFoldDirWithPath(name, fullPath) {
					size, err := calculateDirSizeFast(ctx, fullPath, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
					result = scanResult{TotalSize: size, State: measurementState(size, err), transientFailure: isTransientFailure(err)}
				} else {
					result = scanSubdir(ctx, fullPath, largeFileChan, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
				}
				if ctx.Err() != nil {
					return
				}
				noteChildResult(result)
				atomic.AddInt64(&total, result.TotalSize)
				if result.TotalFiles > 0 {
					subtreeFilesScanned.Add(result.TotalFiles)
				}
				atomic.AddInt64(dirsScanned, 1)
				trySend(ctx, entryChan, dirEntry{
					Name:  name,
					Path:  fullPath,
					Size:  result.TotalSize,
					State: result.State,
					IsDir: true,
				}, scanSendTimeout)
			}
			if limiter.tryAcquireEntry() {
				wg.Add(1)
				go func() {
					defer wg.Done()
					defer limiter.releaseEntry()
					processDir()
				}()
			} else {
				processDir()
			}
			continue
		}

		info, err := child.Info()
		if err != nil {
			noteFailure(err)
			continue
		}
		size := diskSize(fullPath, info)
		atomic.AddInt64(&total, size)
		localFilesScanned++
		localBytesScanned += size

		trySend(ctx, entryChan, dirEntry{
			Name:       child.Name(),
			Path:       fullPath,
			Size:       size,
			LastAccess: lastAccessTime(info),
		}, scanSendTimeout)

		if !shouldSkipFileForLargeTracking(fullPath) && size >= atomic.LoadInt64(&largeFileMinSize) {
			trySend(ctx, largeFileChan, fileEntry{Name: child.Name(), Path: fullPath, Size: size}, scanSendTimeout)
		}
	}

	if localFilesScanned > 0 {
		atomic.AddInt64(filesScanned, localFilesScanned)
	}
	if localBytesScanned > 0 {
		atomic.AddInt64(bytesScanned, localBytesScanned)
	}

	wg.Wait()
	close(entryChan)
	close(largeFileChan)
	collectorWg.Wait()
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}

	var entries []dirEntry
	if collectAllEntries {
		entries = allEntries
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

func scanSubdir(ctx context.Context, root string, largeFileChan chan<- fileEntry, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) scanResult {
	if ctx.Err() != nil {
		return scanResult{}
	}
	result, err := scanPathConcurrent(ctx, root, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
	if err == nil {
		publishLargeFiles(ctx, result.LargeFiles, largeFileChan)
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

	// npm's content-addressed cache fans out into thousands of tiny folders.
	lower := strings.ToLower(path)
	if strings.Contains(lower, `\npm-cache\`) || strings.Contains(lower, `/.npm/`) {
		parent := filepath.Base(filepath.Dir(path))
		if strings.EqualFold(parent, "npm-cache") || parent == ".npm" || strings.HasPrefix(parent, "_") {
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

// calculateDirSizeFast sizes root with a bounded concurrent walk. Only real
// directories are descended into: Go reports junctions and directory symbolic
// links without the directory bit, so they are never followed.
func calculateDirSizeFast(ctx context.Context, root string, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (int64, error) {
	return walkDirSize(ctx, root, "", limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
}

// walkDirSize is calculateDirSizeFast with one immediate child of root left
// out, which keeps the overview's Home row from counting AppData twice.
func walkDirSize(ctx context.Context, root, excludePath string, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) (int64, error) {
	var total atomic.Int64
	var wg sync.WaitGroup
	var failures scanFailures

	ctx, cancel := context.WithTimeout(ctx, fastWalkTimeout)
	defer cancel()

	if limiter == nil {
		limiter = newScanLimiter(0)
	}
	sem := limiter.walkSem
	var fileCounter int64
	if filesScanned == nil {
		filesScanned = &fileCounter
	}
	var dirCounter int64
	if dirsScanned == nil {
		dirsScanned = &dirCounter
	}
	var byteCounter int64
	if bytesScanned == nil {
		bytesScanned = &byteCounter
	}

	var walk func(string)
	walk = func(dirPath string) {
		if ctx.Err() != nil {
			return
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
				break
			}
			if entry.IsDir() {
				subDir := filepath.Join(dirPath, entry.Name())
				if excludePath != "" && dirPath == root && strings.EqualFold(subDir, excludePath) {
					continue
				}
				atomic.AddInt64(dirsScanned, 1)
				select {
				case sem <- struct{}{}:
					wg.Add(1)
					go func() {
						defer wg.Done()
						defer func() { <-sem }()
						walk(subDir)
					}()
				default:
					// Walk inline when no slot is free, so high fan-out cannot deadlock.
					walk(subDir)
				}
				continue
			}
			info, err := entry.Info()
			if err != nil {
				failures.record(err)
				continue
			}
			localBytes += diskSize(filepath.Join(dirPath, entry.Name()), info)
			localFiles++
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

var (
	// overviewWalkTimeout bounds an overview row. A row has no fallback after
	// its deadline and shows a spinner meanwhile, so a normal walk of a large
	// AppData or Program Files must finish rather than read as unknown.
	overviewWalkTimeout = 5 * time.Minute
	// jsonWalkTimeout bounds an overview row in --json, which prints nothing
	// until every row lands and whose callers often have shorter tool
	// timeouts of their own.
	jsonWalkTimeout = 30 * time.Second
)

// measureOverviewSize measures one overview row. A drive row reports the
// volume's used space, which is instant and covers what a walk cannot read;
// the Home row leaves out AppData, which has its own row.
func measureOverviewSize(ctx context.Context, path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return 0, fmt.Errorf("path must be absolute: %s", path)
	}
	if _, err := os.Stat(path); err != nil {
		return 0, fmt.Errorf("cannot access path: %w", err)
	}
	if isVolumeRoot(path) {
		return volumeUsedBytes(path)
	}

	excludePath := ""
	if home := userProfileDir(); home != "" && strings.EqualFold(path, filepath.Clean(home)) {
		excludePath = filepath.Join(path, "AppData")
	}

	ctx, cancel := context.WithTimeout(ctx, overviewWalkTimeout)
	defer cancel()
	return walkDirSize(ctx, path, excludePath, nil, nil, nil, nil, nil)
}
