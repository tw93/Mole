//go:build darwin

package main

import (
	"container/heap"
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

var nextLiveScanID atomic.Int64

type liveScanTargetKind int

const (
	liveScanTargetDirectory liveScanTargetKind = iota + 1
	liveScanTargetFoldedDirectory
	liveScanTargetHomeLibrary
)

type liveScanTarget struct {
	name string
	path string
	kind liveScanTargetKind
}

// liveScanEventStream uses the scan publication boundary for event delivery.
// Progress is lossy and may use only the non-reserved portion of the buffer;
// one slot per target plus the final completion slot stays available.
type liveScanEventStream struct {
	publication   *scanPublication
	events        chan liveScanEventMsg
	requiredSlots int
	closed        bool
}

func newLiveScanEventStream(publication *scanPublication, targetCount int) *liveScanEventStream {
	return &liveScanEventStream{
		publication:   publication,
		events:        make(chan liveScanEventMsg, max(targetCount*4, 1)),
		requiredSlots: targetCount + 1,
	}
}

func (s *liveScanEventStream) cancel() {
	s.publication.cancel()
}

func (s *liveScanEventStream) publish(msg liveScanEventMsg) {
	_ = s.publication.commit(func() error {
		if s.closed {
			return nil
		}
		// Progress publication reserves enough capacity that every target can
		// emit one result or failure and the coordinator can emit completion.
		s.events <- msg
		return nil
	})
}

func (s *liveScanEventStream) publishProgress(msg liveScanEventMsg) {
	_ = s.publication.commit(func() error {
		if s.closed || len(s.events) >= cap(s.events)-s.requiredSlots {
			return nil
		}
		s.events <- msg
		return nil
	})
}

func (s *liveScanEventStream) close() {
	s.publication.finish(func() {
		if s.closed {
			return
		}
		s.closed = true
		close(s.events)
	})
}

func startLiveScanCmd(path string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value) tea.Cmd {
	return startLiveScanCmdWithPolicy(path, filesScanned, dirsScanned, bytesScanned, currentPath, scanCacheReuse)
}

func startLiveScanCmdWithPolicy(path string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, cachePolicy scanCachePolicy) tea.Cmd {
	return func() tea.Msg {
		id := nextLiveScanID.Add(1)
		ctx, cancelContext := context.WithCancel(context.Background())

		limiter := newScanLimiter(0)
		initial, targets, err := readLiveScanInitialEntries(path, limiter)
		if err != nil {
			cancelContext()
			return liveScanStartMsg{id: id, path: path, err: err}
		}

		if initial.TotalFiles > 0 {
			atomic.AddInt64(filesScanned, initial.TotalFiles)
		}
		if initial.TotalSize > 0 {
			atomic.AddInt64(bytesScanned, initial.TotalSize)
		}

		publication := newScanPublication(ctx, cancelContext)
		stream := newLiveScanEventStream(publication, len(targets))
		go runLiveScan(ctx, id, path, initial, targets, limiter, filesScanned, dirsScanned, bytesScanned, currentPath, stream, cachePolicy)

		scanningPaths := make([]string, 0, len(targets))
		for _, target := range targets {
			scanningPaths = append(scanningPaths, target.path)
		}

		return liveScanStartMsg{
			state:         initial.State,
			id:            id,
			path:          path,
			entries:       initial.Entries,
			totalSize:     initial.TotalSize,
			totalFiles:    initial.TotalFiles,
			largeFiles:    initial.LargeFiles,
			scanningPaths: scanningPaths,
			events:        stream.events,
			cancel:        stream.cancel,
		}
	}
}

func readLiveScanInitialEntries(root string, limiter *scanLimiter) (scanResult, []liveScanTarget, error) {
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, nil, err
	}
	if limiter == nil {
		limiter = newScanLimiter(len(children))
	}

	isRootDir := root == "/"
	home := os.Getenv("HOME")
	isHomeDir := home != "" && root == home

	entries := make([]dirEntry, 0, len(children))
	targets := make([]liveScanTarget, 0, len(children))
	largeFiles := make([]fileEntry, 0)
	var totalSize int64
	var totalFiles int64
	state := scanComplete

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		if child.Type()&fs.ModeSymlink != 0 {
			targetInfo, err := os.Stat(fullPath)
			isDir := false
			if err == nil && targetInfo.IsDir() {
				isDir = true
			}
			info, err := child.Info()
			if err != nil {
				state = scanPartial
				continue
			}
			size := getActualFileSize(fullPath, info)
			totalSize += size
			entries = append(entries, dirEntry{
				Name:       child.Name() + " →",
				Path:       fullPath,
				Size:       size,
				IsDir:      isDir,
				LastAccess: getLastAccessTimeFromInfo(info),
			})
			continue
		}

		if child.IsDir() {
			if defaultSkipDirs[child.Name()] {
				continue
			}
			if isRootDir && skipSystemDirs[child.Name()] {
				continue
			}

			targetKind := liveScanTargetDirectory
			if isHomeDir && child.Name() == "Library" {
				targetKind = liveScanTargetHomeLibrary
			} else if shouldFoldDirWithPath(child.Name(), fullPath) {
				targetKind = liveScanTargetFoldedDirectory
			}

			entries = append(entries, dirEntry{
				Name:  child.Name(),
				Path:  fullPath,
				Size:  -1,
				IsDir: true,
			})
			targets = append(targets, liveScanTarget{
				name: child.Name(),
				path: fullPath,
				kind: targetKind,
			})
			continue
		}

		info, err := child.Info()
		if err != nil {
			state = scanPartial
			continue
		}
		size, _ := countableFileSize(info, &limiter.seen)
		totalSize += size
		totalFiles++
		entries = append(entries, dirEntry{
			Name:       child.Name(),
			Path:       fullPath,
			Size:       size,
			IsDir:      false,
			LastAccess: getLastAccessTimeFromInfo(info),
		})
		if !shouldSkipFileForLargeTracking(fullPath) && size >= largeFileWarmupMinSize {
			largeFiles = append(largeFiles, fileEntry{Name: child.Name(), Path: fullPath, Size: size})
		}
	}

	sortDirEntriesBySize(entries)
	largeFiles = topLargeFiles(largeFiles)
	return scanResult{Entries: entries, TotalSize: totalSize, TotalFiles: totalFiles, LargeFiles: largeFiles, State: state}, targets, nil
}

func runLiveScan(
	ctx context.Context,
	id int64,
	root string,
	initial scanResult,
	targets []liveScanTarget,
	limiter *scanLimiter,
	filesScanned, dirsScanned, bytesScanned *int64,
	currentPath *atomic.Value,
	stream *liveScanEventStream,
	cachePolicy scanCachePolicy,
) {
	defer stream.close()

	entriesByPath := make(map[string]dirEntry, len(initial.Entries))
	for _, entry := range initial.Entries {
		entriesByPath[entry.Path] = entry
	}

	var totalSize atomic.Int64
	var totalFiles atomic.Int64
	totalSize.Store(initial.TotalSize)
	totalFiles.Store(initial.TotalFiles)

	largeFileChan := make(chan fileEntry, maxLargeFiles*2)
	largeFileMinSize := int64(largeFileWarmupMinSize)
	largeFilesDone := make(chan []fileEntry, 1)
	go collectLiveLargeFiles(initial.LargeFiles, largeFileChan, &largeFileMinSize, largeFilesDone)

	var dedupedHardlink atomic.Bool
	var incomplete atomic.Bool
	incomplete.Store(initial.State != scanComplete)
	var mu sync.Mutex
	var wg sync.WaitGroup

	for _, target := range targets {
		if ctx.Err() != nil {
			break
		}
		target := target
		scanTarget := func() {
			defer wg.Done()
			result, err := scanLiveTargetWithProgress(ctx, id, root, target, largeFileChan, limiter, currentPath, stream, cachePolicy)
			if err != nil && !errors.Is(err, context.Canceled) {
				incomplete.Store(true)
				mu.Lock()
				entriesByPath[target.path] = dirEntry{Name: target.name, Path: target.path, IsDir: true, State: scanUnavailable}
				mu.Unlock()
				stream.publish(liveScanEventMsg{id: id, path: root, kind: liveScanFailed, entry: dirEntry{Name: target.name, Path: target.path, IsDir: true, State: scanUnavailable}, err: err})
				return
			}
			if ctx.Err() != nil {
				return
			}

			entry := dirEntry{
				Name:  target.name,
				Path:  target.path,
				Size:  result.TotalSize,
				State: result.State,
				IsDir: true,
			}
			mu.Lock()
			entriesByPath[target.path] = entry
			mu.Unlock()

			if result.State != scanComplete {
				incomplete.Store(true)
			}
			totalSize.Add(result.TotalSize)
			if result.TotalFiles > 0 {
				totalFiles.Add(result.TotalFiles)
			}
			if result.dedupedHardlink {
				dedupedHardlink.Store(true)
			}
			atomic.AddInt64(dirsScanned, 1)
			if result.TotalFiles > 0 {
				atomic.AddInt64(filesScanned, result.TotalFiles)
			}
			if result.TotalSize > 0 {
				atomic.AddInt64(bytesScanned, result.TotalSize)
			}

			stream.publish(liveScanEventMsg{
				id:     id,
				path:   root,
				kind:   liveScanChildDone,
				entry:  entry,
				result: result,
			})
		}

		wg.Add(1)
		if limiter.tryAcquireEntry() {
			go func() {
				defer limiter.releaseEntry()
				scanTarget()
			}()
		} else {
			scanTarget()
		}
	}

	wg.Wait()
	close(largeFileChan)
	largeFiles := <-largeFilesDone

	if ctx.Err() != nil {
		return
	}

	mu.Lock()
	finalEntries := make([]dirEntry, 0, len(entriesByPath))
	for _, entry := range entriesByPath {
		finalEntries = append(finalEntries, entry)
	}
	mu.Unlock()
	sortDirEntriesBySize(finalEntries)
	if len(finalEntries) > maxEntries {
		finalEntries = finalEntries[:maxEntries]
	}

	state := scanComplete
	if incomplete.Load() {
		state = scanPartial
	}
	result := scanResult{
		State:           state,
		Entries:         finalEntries,
		LargeFiles:      largeFiles,
		TotalSize:       totalSize.Load(),
		TotalFiles:      totalFiles.Load(),
		dedupedHardlink: dedupedHardlink.Load(),
	}

	stream.publish(liveScanEventMsg{id: id, path: root, kind: liveScanComplete, result: result})
}

func scanLiveTargetWithProgress(ctx context.Context, id int64, root string, target liveScanTarget, largeFileChan chan<- fileEntry, limiter *scanLimiter, currentPath *atomic.Value, stream *liveScanEventStream, cachePolicy scanCachePolicy) (scanResult, error) {
	var filesScanned int64
	var dirsScanned int64
	var bytesScanned int64
	localCurrentPath := &atomic.Value{}
	localCurrentPath.Store("")
	done := make(chan struct{})
	progressDone := make(chan struct{})

	go func() {
		defer close(progressDone)
		ticker := time.NewTicker(uiTickInterval * 2)
		defer ticker.Stop()

		var lastSize int64
		for {
			select {
			case <-ctx.Done():
				return
			case <-done:
				return
			case <-ticker.C:
				size := atomic.LoadInt64(&bytesScanned)
				if size <= 0 || size == lastSize {
					continue
				}
				lastSize = size
				if currentPath != nil {
					if path, _ := localCurrentPath.Load().(string); path != "" {
						currentPath.Store(path)
					}
				}
				stream.publishProgress(liveScanEventMsg{
					id:   id,
					path: root,
					kind: liveScanChildProgress,
					entry: dirEntry{
						Name:  target.name,
						Path:  target.path,
						Size:  size,
						IsDir: true,
					},
				})
			}
		}
	}()

	result, err := scanLiveTarget(ctx, target, largeFileChan, limiter, &filesScanned, &dirsScanned, &bytesScanned, localCurrentPath, cachePolicy, stream.publication)
	close(done)
	<-progressDone
	if result.TotalFiles == 0 {
		result.TotalFiles = atomic.LoadInt64(&filesScanned)
	}
	if result.TotalSize == 0 {
		result.TotalSize = atomic.LoadInt64(&bytesScanned)
	}
	return result, err
}

func scanLiveTarget(ctx context.Context, target liveScanTarget, largeFileChan chan<- fileEntry, limiter *scanLimiter, filesScanned, dirsScanned, bytesScanned *int64, currentPath *atomic.Value, cachePolicy scanCachePolicy, publication *scanPublication) (scanResult, error) {
	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}

	switch target.kind {
	case liveScanTargetHomeLibrary:
		if cachePolicy == scanCacheReuse {
			if cached, err := loadStoredOverviewSize(target.path); err == nil && cached > 0 {
				return scanResult{TotalSize: cached}, nil
			}
		}
	case liveScanTargetFoldedDirectory:
		size, err := getDirectorySizeFromDu(ctx, target.path)
		if ctx.Err() != nil {
			return scanResult{}, ctx.Err()
		}
		if size <= 0 && err != nil {
			size, err = calculateDirSizeFastWithLimiter(ctx, target.path, limiter, filesScanned, dirsScanned, bytesScanned, currentPath)
		} else {
			atomic.AddInt64(bytesScanned, size)
		}
		if ctx.Err() != nil {
			return scanResult{}, ctx.Err()
		}
		return scanResult{TotalSize: size, State: measurementState(size, err)}, nil
	}

	if err := ctx.Err(); err != nil {
		return scanResult{}, err
	}

	result := scanSubdirWithCache(ctx, target.path, largeFileChan, limiter, filesScanned, dirsScanned, bytesScanned, currentPath, cachePolicy, publication)
	return result, ctx.Err()
}

func collectLiveLargeFiles(initial []fileEntry, largeFileChan <-chan fileEntry, largeFileMinSize *int64, done chan<- []fileEntry) {
	h := &largeFileHeap{}
	heap.Init(h)
	for _, file := range initial {
		pushLiveLargeFile(h, file, largeFileMinSize)
	}
	for file := range largeFileChan {
		pushLiveLargeFile(h, file, largeFileMinSize)
	}
	files := make([]fileEntry, h.Len())
	for i := range slices.Backward(files) {
		files[i] = heap.Pop(h).(fileEntry)
	}
	done <- files
}

func pushLiveLargeFile(h *largeFileHeap, file fileEntry, largeFileMinSize *int64) {
	if h.Len() < maxLargeFiles {
		heap.Push(h, file)
		if h.Len() == maxLargeFiles {
			atomic.StoreInt64(largeFileMinSize, (*h)[0].Size)
		}
		return
	}
	if file.Size > (*h)[0].Size {
		heap.Pop(h)
		heap.Push(h, file)
		atomic.StoreInt64(largeFileMinSize, (*h)[0].Size)
	}
}

func waitLiveScanEventCmd(events <-chan liveScanEventMsg) tea.Cmd {
	return func() tea.Msg {
		msg, ok := <-events
		if !ok {
			return nil
		}
		return msg
	}
}

func sortDirEntriesBySize(entries []dirEntry) {
	sort.SliceStable(entries, func(i, j int) bool {
		return entries[i].Size > entries[j].Size
	})
}

func topLargeFiles(files []fileEntry) []fileEntry {
	if len(files) <= maxLargeFiles {
		sort.SliceStable(files, func(i, j int) bool {
			return files[i].Size > files[j].Size
		})
		return files
	}
	h := &largeFileHeap{}
	heap.Init(h)
	var minSize int64 = largeFileWarmupMinSize
	for _, file := range files {
		pushLiveLargeFile(h, file, &minSize)
	}
	top := make([]fileEntry, h.Len())
	for i := range slices.Backward(top) {
		top[i] = heap.Pop(h).(fileEntry)
	}
	return top
}
