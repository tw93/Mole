//go:build darwin

package main

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func (m *model) scheduleOverviewScans() tea.Cmd {
	if !m.inOverviewMode() {
		return nil
	}

	var pendingIndices []int
	for i, entry := range m.entries {
		if entry.Size < 0 && !m.overviewScanningSet[entry.Path] {
			pendingIndices = append(pendingIndices, i)
			if len(pendingIndices) >= maxConcurrentOverview {
				break
			}
		}
	}

	if len(pendingIndices) == 0 {
		m.overviewScanning = false
		if !hasPendingOverviewEntries(m.entries) {
			m.sortOverviewEntriesBySize()
			m.status = "Ready"
		}
		return nil
	}

	var cmds []tea.Cmd
	for _, idx := range pendingIndices {
		entry := m.entries[idx]
		m.overviewScanningSet[entry.Path] = true
		cmd := scanOverviewPathCmd(entry.Path, idx)
		cmds = append(cmds, cmd)
	}

	m.overviewScanning = true
	remaining := 0
	for _, e := range m.entries {
		if e.Size < 0 {
			remaining++
		}
	}
	if len(pendingIndices) > 0 {
		firstEntry := m.entries[pendingIndices[0]]
		if len(pendingIndices) == 1 {
			m.status = fmt.Sprintf("Scanning %s..., %d left", firstEntry.Name, remaining)
		} else {
			m.status = fmt.Sprintf("Scanning %d directories..., %d left", len(pendingIndices), remaining)
		}
	}

	cmds = append(cmds, tickCmd())
	return tea.Batch(cmds...)
}

func (m model) Init() tea.Cmd {
	if m.inOverviewMode() {
		return m.scheduleOverviewScans()
	}
	return tea.Batch(m.scanCmd(m.path), tickCmd())
}

func (m model) scanCmd(path string) tea.Cmd {
	return func() tea.Msg {
		if cached, err := loadCacheFromDisk(path); err == nil {
			result := scanResult{
				Entries:    cached.Entries,
				LargeFiles: cached.LargeFiles,
				TotalSize:  cached.TotalSize,
				TotalFiles: cached.TotalFiles,
			}
			if cached.NeedsRefresh {
				return scanResultMsg{path: path, result: result, err: nil, stale: true}
			}
			return scanResultMsg{path: path, result: result, err: nil}
		}

		if stale, err := loadStaleCacheFromDisk(path); err == nil {
			result := scanResult{
				Entries:    stale.Entries,
				LargeFiles: stale.LargeFiles,
				TotalSize:  stale.TotalSize,
				TotalFiles: stale.TotalFiles,
			}
			return scanResultMsg{path: path, result: result, err: nil, stale: true}
		}

		v, err, _ := scanGroup.Do(path, func() (any, error) {
			return scanPathConcurrent(path, m.filesScanned, m.dirsScanned, m.bytesScanned, m.currentPath)
		})

		if err != nil {
			return scanResultMsg{path: path, err: err}
		}

		result := v.(scanResult)

		go func(p string, r scanResult) {
			if err := saveCacheToDisk(p, r); err != nil {
				_ = err // Cache save failure is not critical
			}
		}(path, result)

		return scanResultMsg{path: path, result: result, err: nil}
	}
}

func (m model) scanFreshCmd(path string) tea.Cmd {
	return func() tea.Msg {
		v, err, _ := scanGroup.Do(path, func() (any, error) {
			return scanPathConcurrent(path, m.filesScanned, m.dirsScanned, m.bytesScanned, m.currentPath)
		})

		if err != nil {
			return scanResultMsg{path: path, err: err}
		}

		result := v.(scanResult)
		go func(p string, r scanResult) {
			if err := saveCacheToDisk(p, r); err != nil {
				_ = err
			}
		}(path, result)

		return scanResultMsg{path: path, result: result}
	}
}

func tickCmd() tea.Cmd {
	return tea.Tick(uiTickInterval, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		return m.updateKey(msg)
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil
	case deleteProgressMsg:
		if msg.done {
			m.deleting = false
			m.multiSelected = make(map[string]bool)
			m.largeMultiSelected = make(map[string]bool)
			if msg.err != nil {
				m.status = fmt.Sprintf("Failed to delete: %v", msg.err)
			} else {
				if msg.path != "" {
					m.removePathFromView(msg.path)
					invalidateCache(msg.path)
				}
				invalidateCache(m.path)
				m.status = fmt.Sprintf("Deleted %d items", msg.count)

				// Selective invalidation: only mark current path and ancestors as needing refresh
				currentPath := m.path
				for currentPath != "/" && currentPath != "" {
					if entry, exists := m.cache[currentPath]; exists {
						entry.NeedsRefresh = true
						m.cache[currentPath] = entry
					}
					currentPath = filepath.Dir(currentPath)
				}

				// Mark history entries for current path and ancestors as needing refresh
				for i := range m.history {
					histPath := m.history[i].Path
					if histPath == m.path || strings.HasPrefix(m.path, histPath+"/") {
						m.history[i].NeedsRefresh = true
					}
				}

				m.scanning = true
				atomic.StoreInt64(m.filesScanned, 0)
				atomic.StoreInt64(m.dirsScanned, 0)
				atomic.StoreInt64(m.bytesScanned, 0)
				if m.currentPath != nil {
					m.currentPath.Store("")
				}
				return m, tea.Batch(m.scanCmd(m.path), tickCmd())
			}
		}
		return m, nil
	case scanResultMsg:
		if msg.path != "" && msg.path != m.path {
			if msg.err == nil {
				filteredEntries := filterNonEmptyEntries(msg.result.Entries)
				result := msg.result
				result.Entries = filteredEntries
				m.cache[msg.path] = historyEntryFromScanResult(msg.path, result, m.cache[msg.path], msg.stale)
			}
			return m, nil
		}
		m.scanning = false
		if msg.err != nil {
			m.status = fmt.Sprintf("Scan failed: %v", msg.err)
			return m, nil
		}
		filteredEntries := filterNonEmptyEntries(msg.result.Entries)
		result := msg.result
		result.Entries = filteredEntries
		m.entriesAll = filteredEntries
		m.entries = filteredEntries
		m.largeFilesAll = msg.result.LargeFiles
		m.largeFiles = msg.result.LargeFiles
		m.totalSize = msg.result.TotalSize
		m.totalFiles = msg.result.TotalFiles
		m.viewNeedsRefresh = msg.stale
		// Re-narrow to the active query if a background refresh landed while a
		// filter is showing; each is a no-op (restores the full list) when its
		// query is empty.
		m.applyEntryFilter()
		m.applyLargeFilter()
		m.cache[m.path] = historyEntryFromScanResult(m.path, result, m.cache[m.path], msg.stale)
		if m.totalSize > 0 {
			if m.overviewSizeCache == nil {
				m.overviewSizeCache = make(map[string]int64)
			}
			m.overviewSizeCache[m.path] = m.totalSize
			go func(path string, size int64) {
				_ = storeOverviewSize(path, size)
			}(m.path, m.totalSize)
		}

		if msg.stale {
			m.status = fmt.Sprintf("Loaded cached data for %s, refreshing...", displayPath(m.path))
			m.scanning = true
			if m.totalFiles > 0 {
				m.lastTotalFiles = m.totalFiles
			}
			atomic.StoreInt64(m.filesScanned, 0)
			atomic.StoreInt64(m.dirsScanned, 0)
			atomic.StoreInt64(m.bytesScanned, 0)
			if m.currentPath != nil {
				m.currentPath.Store("")
			}
			return m, tea.Batch(m.scanFreshCmd(m.path), tickCmd())
		}

		m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		return m, nil
	case overviewSizeMsg:
		delete(m.overviewScanningSet, msg.Path)

		if msg.Err == nil {
			if m.overviewSizeCache == nil {
				m.overviewSizeCache = make(map[string]int64)
			}
			m.overviewSizeCache[msg.Path] = msg.Size
		}

		if m.inOverviewMode() {
			for i := range m.entries {
				if m.entries[i].Path == msg.Path {
					if msg.Err == nil {
						m.entries[i].Size = msg.Size
					} else {
						m.entries[i].Size = 0
					}
					break
				}
			}
			m.totalSize = sumKnownEntrySizes(m.entries)

			if msg.Err != nil {
				m.status = fmt.Sprintf("Unable to measure %s: %v", displayPath(msg.Path), msg.Err)
			}

			cmd := m.scheduleOverviewScans()
			return m, cmd
		}
		return m, nil
	case tickMsg:
		hasPending := false
		if m.inOverviewMode() {
			for _, entry := range m.entries {
				if entry.Size < 0 {
					hasPending = true
					break
				}
			}
		}
		if m.scanning || m.deleting || (m.inOverviewMode() && (m.overviewScanning || hasPending)) {
			m.spinner = (m.spinner + 1) % len(spinnerFrames)
			if m.deleting && m.deleteCount != nil {
				count := atomic.LoadInt64(m.deleteCount)
				if count > 0 {
					m.status = fmt.Sprintf("Moving to Trash... %s items", formatNumber(count))
				}
			}
			return m, tickCmd()
		}
		return m, nil
	default:
		return m, nil
	}
}

func (m model) updateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Delete confirm flow.
	if m.deleteConfirm {
		switch msg.String() {
		case "enter":
			m.deleteConfirm = false
			m.deleting = true
			var deleteCount int64
			m.deleteCount = &deleteCount

			// Collect paths (safer than indices).
			var pathsToDelete []string
			if m.showLargeFiles {
				if len(m.largeMultiSelected) > 0 {
					for path := range m.largeMultiSelected {
						pathsToDelete = append(pathsToDelete, path)
					}
				} else if m.deleteTarget != nil {
					pathsToDelete = append(pathsToDelete, m.deleteTarget.Path)
				}
			} else {
				if len(m.multiSelected) > 0 {
					for path := range m.multiSelected {
						pathsToDelete = append(pathsToDelete, path)
					}
				} else if m.deleteTarget != nil {
					pathsToDelete = append(pathsToDelete, m.deleteTarget.Path)
				}
			}

			m.deleteTarget = nil
			if len(pathsToDelete) == 0 {
				m.deleting = false
				m.status = "Nothing to delete"
				return m, nil
			}

			if len(pathsToDelete) == 1 {
				targetPath := pathsToDelete[0]
				m.status = fmt.Sprintf("Deleting %s...", filepath.Base(targetPath))
				return m, tea.Batch(deletePathCmd(targetPath, m.deleteCount), tickCmd())
			}

			m.status = fmt.Sprintf("Deleting %d items...", len(pathsToDelete))
			return m, tea.Batch(deleteMultiplePathsCmd(pathsToDelete, m.deleteCount), tickCmd())
		case "esc", "q":
			m.status = "Cancelled"
			m.deleteConfirm = false
			m.deleteTarget = nil
			return m, nil
		case "ctrl+c":
			return m, tea.Quit
		default:
			return m, nil
		}
	}

	// Filter prompts swallow all keys while the user types a query.
	if m.largeFiltering {
		return m.updateLargeFilterInput(msg)
	}
	if m.entryFiltering {
		return m.updateEntryFilterInput(msg)
	}

	switch msg.String() {
	case "q", "Q", "ctrl+c":
		return m, tea.Quit
	case "esc":
		if m.showLargeFiles {
			if m.largeFilter != "" {
				m.resetLargeFilter()
				m.clampLargeSelection()
				m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
				return m, nil
			}
			m.showLargeFiles = false
			return m, nil
		}
		if m.entryFilter != "" {
			m.resetEntryFilter()
			m.clampEntrySelection()
			m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
			return m, nil
		}
		return m.goBack()
	case "up", "k", "K":
		if m.showLargeFiles {
			if m.largeSelected > 0 {
				m.largeSelected--
				if m.largeSelected < m.largeOffset {
					m.largeOffset = m.largeSelected
				}
			}
		} else if len(m.entries) > 0 && m.selected > 0 {
			next := m.selected - 1
			for next > 0 && m.entries[next].Size == 0 {
				next--
			}
			m.selected = next
			if m.selected < m.offset {
				m.offset = m.selected
			}
		}
	case "down", "j", "J":
		if m.showLargeFiles {
			if m.largeSelected < len(m.largeFiles)-1 {
				m.largeSelected++
				viewport := calculateViewport(m.height, true)
				if m.largeSelected >= m.largeOffset+viewport {
					m.largeOffset = m.largeSelected - viewport + 1
				}
			}
		} else if len(m.entries) > 0 && m.selected < len(m.entries)-1 {
			next := m.selected + 1
			for next < len(m.entries)-1 && m.entries[next].Size == 0 {
				next++
			}
			m.selected = next
			viewport := calculateViewport(m.height, false)
			if m.selected >= m.offset+viewport {
				m.offset = m.selected - viewport + 1
			}
		}
	case "enter", "right", "l", "L":
		if m.showLargeFiles {
			return m, nil
		}
		return m.enterSelectedDir()
	case "b", "left", "h", "B", "H":
		if m.showLargeFiles {
			m.showLargeFiles = false
			m.resetLargeFilter()
			return m, nil
		}
		return m.goBack()
	case "r", "R":
		m.multiSelected = make(map[string]bool)
		m.largeMultiSelected = make(map[string]bool)

		if m.inOverviewMode() {
			// Explicitly invalidate cache for all overview entries to force re-scan
			for _, entry := range m.entries {
				invalidateCache(entry.Path)
			}

			m.overviewSizeCache = make(map[string]int64)
			m.overviewScanningSet = make(map[string]bool)
			m.hydrateOverviewEntries() // Reset sizes to pending

			for i := range m.entries {
				m.entries[i].Size = -1
			}
			m.totalSize = 0

			m.status = "Refreshing..."
			m.overviewScanning = true
			return m, tea.Batch(m.scheduleOverviewScans(), tickCmd())
		}

		invalidateCacheTree(m.path)
		m.status = "Refreshing..."
		m.scanning = true
		if m.totalFiles > 0 {
			m.lastTotalFiles = m.totalFiles
		}
		atomic.StoreInt64(m.filesScanned, 0)
		atomic.StoreInt64(m.dirsScanned, 0)
		atomic.StoreInt64(m.bytesScanned, 0)
		if m.currentPath != nil {
			m.currentPath.Store("")
		}
		return m, tea.Batch(m.scanFreshCmd(m.path), tickCmd())
	case "t", "T":
		if !m.inOverviewMode() {
			m.showLargeFiles = !m.showLargeFiles
			m.resetLargeFilter()
			m.resetEntryFilter()
			if m.showLargeFiles {
				m.largeSelected = 0
				m.largeOffset = 0
				m.largeMultiSelected = make(map[string]bool)
			} else {
				m.multiSelected = make(map[string]bool)
			}
			m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		}
	case "/":
		if m.inOverviewMode() {
			break
		}
		if m.showLargeFiles {
			if len(m.largeFilesAll) > 0 {
				m.largeFiltering = true
				m.status = "Filter: type to match, Enter to apply, Esc to clear"
			}
		} else if len(m.entriesAll) > 0 {
			m.entryFiltering = true
			m.status = "Filter: type to match, Enter to apply, Esc to clear"
		}
	case "o", "O":
		// Open selected entries (multi-select aware).
		const maxBatchOpen = 20
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				if len(m.largeMultiSelected) > 0 {
					count := len(m.largeMultiSelected)
					if count > maxBatchOpen {
						m.status = fmt.Sprintf("Too many items to open, max %d, selected %d", maxBatchOpen, count)
						return m, nil
					}
					for path := range m.largeMultiSelected {
						go func(p string) {
							_ = safeOpen(p, false)
						}(path)
					}
					m.status = fmt.Sprintf("Opening %d items...", count)
				} else {
					selected := m.largeFiles[m.largeSelected]
					go func(path string) {
						_ = safeOpen(path, false)
					}(selected.Path)
					m.status = fmt.Sprintf("Opening %s...", selected.Name)
				}
			}
		} else if len(m.entries) > 0 {
			if len(m.multiSelected) > 0 {
				count := len(m.multiSelected)
				if count > maxBatchOpen {
					m.status = fmt.Sprintf("Too many items to open, max %d, selected %d", maxBatchOpen, count)
					return m, nil
				}
				for path := range m.multiSelected {
					go func(p string) {
						_ = safeOpen(p, false)
					}(path)
				}
				m.status = fmt.Sprintf("Opening %d items...", count)
			} else {
				selected := m.entries[m.selected]
				go func(path string) {
					_ = safeOpen(path, false)
				}(selected.Path)
				m.status = fmt.Sprintf("Opening %s...", selected.Name)
			}
		}
	case "f", "F":
		// Reveal in Finder (multi-select aware).
		const maxBatchReveal = 20
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				if len(m.largeMultiSelected) > 0 {
					count := len(m.largeMultiSelected)
					if count > maxBatchReveal {
						m.status = fmt.Sprintf("Too many items to reveal, max %d, selected %d", maxBatchReveal, count)
						return m, nil
					}
					for path := range m.largeMultiSelected {
						go func(p string) {
							_ = safeOpen(p, true)
						}(path)
					}
					m.status = fmt.Sprintf("Showing %d items in Finder...", count)
				} else {
					selected := m.largeFiles[m.largeSelected]
					go func(path string) {
						_ = safeOpen(path, true)
					}(selected.Path)
					m.status = fmt.Sprintf("Showing %s in Finder...", selected.Name)
				}
			}
		} else if len(m.entries) > 0 {
			if len(m.multiSelected) > 0 {
				count := len(m.multiSelected)
				if count > maxBatchReveal {
					m.status = fmt.Sprintf("Too many items to reveal, max %d, selected %d", maxBatchReveal, count)
					return m, nil
				}
				for path := range m.multiSelected {
					go func(p string) {
						_ = safeOpen(p, true)
					}(path)
				}
				m.status = fmt.Sprintf("Showing %d items in Finder...", count)
			} else {
				selected := m.entries[m.selected]
				go func(path string) {
					_ = safeOpen(path, true)
				}(selected.Path)
				m.status = fmt.Sprintf("Showing %s in Finder...", selected.Name)
			}
		}
	case "p", "P":
		// Quick Look preview (single file only, no multi-select).
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				selected := m.largeFiles[m.largeSelected]
				go func(path string) {
					_ = safePreview(path)
				}(selected.Path)
				m.status = fmt.Sprintf("Previewing %s...", selected.Name)
			}
		} else if len(m.entries) > 0 {
			selected := m.entries[m.selected]
			if !selected.IsDir {
				go func(path string) {
					_ = safePreview(path)
				}(selected.Path)
				m.status = fmt.Sprintf("Previewing %s...", selected.Name)
			}
		}
	case " ":
		// Toggle multi-select (paths as keys).
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 && m.largeSelected < len(m.largeFiles) {
				if m.largeMultiSelected == nil {
					m.largeMultiSelected = make(map[string]bool)
				}
				selectedPath := m.largeFiles[m.largeSelected].Path
				if m.largeMultiSelected[selectedPath] {
					delete(m.largeMultiSelected, selectedPath)
				} else {
					m.largeMultiSelected[selectedPath] = true
				}
				count := len(m.largeMultiSelected)
				if count > 0 {
					var totalSize int64
					for path := range m.largeMultiSelected {
						for _, file := range m.largeFiles {
							if file.Path == path {
								totalSize += file.Size
								break
							}
						}
					}
					m.status = fmt.Sprintf("%d selected, %s", count, humanizeBytes(totalSize))
				} else {
					m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
				}
			}
		} else if len(m.entries) > 0 && !m.inOverviewMode() && m.selected < len(m.entries) {
			if m.multiSelected == nil {
				m.multiSelected = make(map[string]bool)
			}
			selectedPath := m.entries[m.selected].Path
			if m.multiSelected[selectedPath] {
				delete(m.multiSelected, selectedPath)
			} else {
				m.multiSelected[selectedPath] = true
			}
			count := len(m.multiSelected)
			if count > 0 {
				var totalSize int64
				for path := range m.multiSelected {
					for _, entry := range m.entries {
						if entry.Path == path {
							totalSize += entry.Size
							break
						}
					}
				}
				m.status = fmt.Sprintf("%d selected, %s", count, humanizeBytes(totalSize))
			} else {
				m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
			}
		}
	case "delete", "backspace":
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				if len(m.largeMultiSelected) > 0 {
					m.deleteConfirm = true
					for path := range m.largeMultiSelected {
						for _, file := range m.largeFiles {
							if file.Path == path {
								m.deleteTarget = &dirEntry{
									Name:  file.Name,
									Path:  file.Path,
									Size:  file.Size,
									IsDir: false,
								}
								break
							}
						}
						break // Only need first one for display
					}
				} else if m.largeSelected < len(m.largeFiles) {
					selected := m.largeFiles[m.largeSelected]
					m.deleteConfirm = true
					m.deleteTarget = &dirEntry{
						Name:  selected.Name,
						Path:  selected.Path,
						Size:  selected.Size,
						IsDir: false,
					}
				}
			}
		} else if len(m.entries) > 0 && !m.inOverviewMode() {
			if len(m.multiSelected) > 0 {
				m.deleteConfirm = true
				for path := range m.multiSelected {
					// Resolve entry by path.
					for i := range m.entries {
						if m.entries[i].Path == path {
							m.deleteTarget = &m.entries[i]
							break
						}
					}
					break // Only need first one for display
				}
			} else if m.selected < len(m.entries) {
				selected := m.entries[m.selected]
				m.deleteConfirm = true
				m.deleteTarget = &selected
			}
		}
	}
	return m, nil
}

// updateLargeFilterInput handles keystrokes while the Top-files filter prompt
// is active. Typing edits the query and re-filters live; Enter applies and
// hands control back to navigation; Esc clears the filter entirely. Navigation
// and action keys are intentionally swallowed so they edit the query instead of
// moving the cursor or deleting files. Changing the query clears any
// multi-selection so an action can never touch a row hidden by the filter.
func (m model) updateLargeFilterInput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.Type {
	case tea.KeyCtrlC:
		return m, tea.Quit
	case tea.KeyEsc:
		m.resetLargeFilter()
		m.clampLargeSelection()
		m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		return m, nil
	case tea.KeyEnter:
		m.largeFiltering = false
		if m.largeFilter == "" {
			m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		} else {
			m.status = fmt.Sprintf("Filter %q, %d matches", m.largeFilter, len(m.largeFiles))
		}
		return m, nil
	case tea.KeyBackspace, tea.KeyDelete:
		if r := []rune(m.largeFilter); len(r) > 0 {
			m.largeFilter = string(r[:len(r)-1])
			m.largeMultiSelected = make(map[string]bool)
			m.applyLargeFilter()
		}
		return m, nil
	case tea.KeySpace:
		m.largeFilter += " "
		m.largeMultiSelected = make(map[string]bool)
		m.applyLargeFilter()
		return m, nil
	case tea.KeyRunes:
		m.largeFilter += string(msg.Runes)
		m.largeMultiSelected = make(map[string]bool)
		m.applyLargeFilter()
		return m, nil
	default:
		return m, nil
	}
}

// updateEntryFilterInput is the directory-view counterpart to
// updateLargeFilterInput: it edits the drill-down filter query live, applies on
// Enter, clears on Esc, and clears multi-selection on any query change so an
// action can never touch a row hidden by the filter.
func (m model) updateEntryFilterInput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.Type {
	case tea.KeyCtrlC:
		return m, tea.Quit
	case tea.KeyEsc:
		m.resetEntryFilter()
		m.clampEntrySelection()
		m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		return m, nil
	case tea.KeyEnter:
		m.entryFiltering = false
		if m.entryFilter == "" {
			m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		} else {
			m.status = fmt.Sprintf("Filter %q, %d matches", m.entryFilter, len(m.entries))
		}
		return m, nil
	case tea.KeyBackspace, tea.KeyDelete:
		if r := []rune(m.entryFilter); len(r) > 0 {
			m.entryFilter = string(r[:len(r)-1])
			m.multiSelected = make(map[string]bool)
			m.applyEntryFilter()
		}
		return m, nil
	case tea.KeySpace:
		m.entryFilter += " "
		m.multiSelected = make(map[string]bool)
		m.applyEntryFilter()
		return m, nil
	case tea.KeyRunes:
		m.entryFilter += string(msg.Runes)
		m.multiSelected = make(map[string]bool)
		m.applyEntryFilter()
		return m, nil
	default:
		return m, nil
	}
}

func (m model) goBack() (tea.Model, tea.Cmd) {
	if len(m.history) == 0 {
		if !m.inOverviewMode() {
			return m, m.switchToOverviewMode()
		}
		return m, tea.Quit
	}

	last := m.history[len(m.history)-1]
	m.history = m.history[:len(m.history)-1]
	m.path = last.Path
	m.selected = last.Selected
	m.offset = last.EntryOffset
	m.largeSelected = last.LargeSelected
	m.largeOffset = last.LargeOffset
	m.isOverview = last.IsOverview
	m.resetEntryFilter()
	m.resetLargeFilter()
	m.entriesAll = last.Entries
	m.entries = last.Entries
	m.largeFilesAll = last.LargeFiles
	m.largeFiles = last.LargeFiles
	m.totalSize = last.TotalSize
	m.totalFiles = last.TotalFiles
	m.viewNeedsRefresh = last.NeedsRefresh
	m.clampEntrySelection()
	m.clampLargeSelection()
	if len(m.entries) == 0 {
		m.selected = 0
	} else if m.selected >= len(m.entries) {
		m.selected = len(m.entries) - 1
	}
	if m.selected < 0 {
		m.selected = 0
	}
	if last.NeedsRefresh {
		m.status = fmt.Sprintf("Loaded cached data for %s, refreshing...", displayPath(m.path))
		m.scanning = true
		if m.totalFiles > 0 {
			m.lastTotalFiles = m.totalFiles
		}
		atomic.StoreInt64(m.filesScanned, 0)
		atomic.StoreInt64(m.dirsScanned, 0)
		atomic.StoreInt64(m.bytesScanned, 0)
		if m.currentPath != nil {
			m.currentPath.Store("")
		}
		return m, tea.Batch(m.scanFreshCmd(m.path), tickCmd())
	}
	m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
	m.scanning = false
	return m, nil
}

func (m *model) switchToOverviewMode() tea.Cmd {
	m.isOverview = true
	m.path = "/"
	m.scanning = false
	m.showLargeFiles = false
	m.entriesAll = nil
	m.resetEntryFilter()
	m.resetLargeFilter()
	m.largeFilesAll = nil
	m.largeFiles = nil
	m.largeSelected = 0
	m.largeOffset = 0
	m.deleteConfirm = false
	m.deleteTarget = nil
	m.selected = 0
	m.offset = 0
	m.hydrateOverviewEntries()
	cmd := m.scheduleOverviewScans()
	if cmd == nil {
		m.status = "Ready"
		return nil
	}
	return tea.Batch(cmd, tickCmd())
}

func (m model) enterSelectedDir() (tea.Model, tea.Cmd) {
	if len(m.entries) == 0 {
		return m, nil
	}
	selected := m.entries[m.selected]
	if selected.IsDir {
		// Drilling in commits and drops any active directory filter so the parent
		// is snapshotted in full. Remap the selection onto the unfiltered list so
		// the entry we enter stays highlighted when we navigate back.
		if m.entryFilter != "" {
			for i := range m.entriesAll {
				if m.entriesAll[i].Path == selected.Path {
					m.selected = i
					break
				}
			}
		}
		m.resetEntryFilter()
		m.clampEntrySelection()

		if len(m.history) == 0 || m.history[len(m.history)-1].Path != m.path {
			m.history = append(m.history, snapshotFromModel(m))
		}
		m.path = selected.Path
		m.selected = 0
		m.offset = 0
		m.status = "Scanning..."
		m.scanning = true
		m.isOverview = false
		m.viewNeedsRefresh = false
		m.multiSelected = make(map[string]bool)
		m.largeMultiSelected = make(map[string]bool)

		atomic.StoreInt64(m.filesScanned, 0)
		atomic.StoreInt64(m.dirsScanned, 0)
		atomic.StoreInt64(m.bytesScanned, 0)
		if m.currentPath != nil {
			m.currentPath.Store("")
		}

		m.resetLargeFilter()
		if cached, ok := m.cache[m.path]; ok {
			m.entriesAll = slices.Clone(cached.Entries)
			m.entries = m.entriesAll
			m.largeFilesAll = slices.Clone(cached.LargeFiles)
			m.largeFiles = m.largeFilesAll
			m.totalSize = cached.TotalSize
			m.totalFiles = cached.TotalFiles
			m.viewNeedsRefresh = cached.NeedsRefresh
			m.selected = cached.Selected
			m.offset = cached.EntryOffset
			m.largeSelected = cached.LargeSelected
			m.largeOffset = cached.LargeOffset
			m.clampEntrySelection()
			m.clampLargeSelection()
			if cached.NeedsRefresh {
				m.status = fmt.Sprintf("Loaded cached data for %s, refreshing...", displayPath(m.path))
				m.scanning = true
				if m.totalFiles > 0 {
					m.lastTotalFiles = m.totalFiles
				}
				return m, tea.Batch(m.scanFreshCmd(m.path), tickCmd())
			}
			m.status = fmt.Sprintf("Cached view for %s", displayPath(m.path))
			m.scanning = false
			return m, nil
		}
		m.lastTotalFiles = 0
		if total, err := peekCacheTotalFiles(m.path); err == nil && total > 0 {
			m.lastTotalFiles = total
		}
		return m, tea.Batch(m.scanCmd(m.path), tickCmd())
	}
	m.status = fmt.Sprintf("File: %s, %s", selected.Name, humanizeBytes(selected.Size))
	return m, nil
}

func scanOverviewPathCmd(path string, index int) tea.Cmd {
	return func() tea.Msg {
		size, err := measureInsightSize(path)
		return overviewSizeMsg{
			Path:  path,
			Index: index,
			Size:  size,
			Err:   err,
		}
	}
}
