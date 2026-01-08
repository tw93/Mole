//go:build darwin

package main

import (
	"fmt"
	"strings"
	"sync/atomic"
)

// View renders the TUI.
func (m model) View() string {
	var b strings.Builder
	fmt.Fprintln(&b)

	if m.inOverviewMode() {
		fmt.Fprintf(&b, "%sAnalyze Disk%s\n", colorPurpleBold, colorReset)
		if m.overviewScanning {
			allPending := true
			for _, entry := range m.entries {
				if entry.Size >= 0 {
					allPending = false
					break
				}
			}

			if allPending {
				fmt.Fprintf(&b, "%s%s%s%s Analyzing disk usage, please wait...%s\n",
					colorCyan, colorBold,
					spinnerFrames[m.spinner],
					colorReset, colorReset)
				return b.String()
			} else {
				fmt.Fprintf(&b, "%sSelect a location to explore:%s  ", colorGray, colorReset)
				fmt.Fprintf(&b, "%s%s%s%s Scanning...\n\n", colorCyan, colorBold, spinnerFrames[m.spinner], colorReset)
			}
		} else {
			hasPending := false
			for _, entry := range m.entries {
				if entry.Size < 0 {
					hasPending = true
					break
				}
			}
			if hasPending {
				fmt.Fprintf(&b, "%sSelect a location to explore:%s  ", colorGray, colorReset)
				fmt.Fprintf(&b, "%s%s%s%s Scanning...\n\n", colorCyan, colorBold, spinnerFrames[m.spinner], colorReset)
			} else {
				fmt.Fprintf(&b, "%sSelect a location to explore:%s\n\n", colorGray, colorReset)
			}
		}
	} else {
		fmt.Fprintf(&b, "%sAnalyze Disk%s  %s%s%s", colorPurpleBold, colorReset, colorGray, displayPath(m.path), colorReset)
		if !m.scanning {
			fmt.Fprintf(&b, "  |  Total: %s", humanizeBytes(m.totalSize))
		}
		fmt.Fprintf(&b, "\n\n")
	}

	if m.deleting {
		count := int64(0)
		if m.deleteCount != nil {
			count = atomic.LoadInt64(m.deleteCount)
		}

		fmt.Fprintf(&b, "%s%s%s%s Deleting: %s%s items%s removed, please wait...\n",
			colorCyan, colorBold,
			spinnerFrames[m.spinner],
			colorReset,
			colorYellow, formatNumber(count), colorReset)

		return b.String()
	}

	if m.scanning {
		filesScanned, dirsScanned, bytesScanned := m.getScanProgress()

		fmt.Fprintf(&b, "%s%s%s%s Scanning: %s%s files%s, %s%s dirs%s, %s%s%s\n",
			colorCyan, colorBold,
			spinnerFrames[m.spinner],
			colorReset,
			colorYellow, formatNumber(filesScanned), colorReset,
			colorYellow, formatNumber(dirsScanned), colorReset,
			colorGreen, humanizeBytes(bytesScanned), colorReset)

		if m.currentPath != nil {
			currentPath := *m.currentPath
			if currentPath != "" {
				shortPath := displayPath(currentPath)
				shortPath = truncateMiddle(shortPath, 50)
				fmt.Fprintf(&b, "%s%s%s\n", colorGray, shortPath, colorReset)
			}
		}

		return b.String()
	}

	if m.showLargeFiles {
		if len(m.largeFiles) == 0 {
			fmt.Fprintln(&b, "  No large files found (>=100MB)")
		} else {
			viewport := calculateViewport(m.height, true)
			start := max(m.largeOffset, 0)
			end := min(start+viewport, len(m.largeFiles))
			maxLargeSize := int64(1)
			for _, file := range m.largeFiles {
				if file.Size > maxLargeSize {
					maxLargeSize = file.Size
				}
			}
			nameWidth := calculateNameWidth(m.width)
			for idx := start; idx < end; idx++ {
				file := m.largeFiles[idx]
				shortPath := displayPath(file.Path)
				shortPath = truncateMiddle(shortPath, nameWidth)
				paddedPath := padName(shortPath, nameWidth)
				entryPrefix := "   "
				nameColor := ""
				sizeColor := colorGray
				numColor := ""

				isMultiSelected := m.largeMultiSelected != nil && m.largeMultiSelected[file.Path]
				selectIcon := "○"
				if isMultiSelected {
					selectIcon = fmt.Sprintf("%s●%s", colorGreen, colorReset)
					nameColor = colorGreen
				}

				if idx == m.largeSelected {
					entryPrefix = fmt.Sprintf(" %s%s▶%s ", colorCyan, colorBold, colorReset)
					if !isMultiSelected {
						nameColor = colorCyan
					}
					sizeColor = colorCyan
					numColor = colorCyan
				}
				size := humanizeBytes(file.Size)
				bar := coloredProgressBar(file.Size, maxLargeSize, 0)
				fmt.Fprintf(&b, "%s%s %s%2d.%s %s  |  📄 %s%s%s  %s%10s%s\n",
					entryPrefix, selectIcon, numColor, idx+1, colorReset, bar, nameColor, paddedPath, colorReset, sizeColor, size, colorReset)
			}
		}
	} else {
		if len(m.entries) == 0 {
			fmt.Fprintln(&b, "  Empty directory")
		} else {
			if m.inOverviewMode() {
				maxSize := int64(1)
				for _, entry := range m.entries {
					if entry.Size > maxSize {
						maxSize = entry.Size
					}
				}
				totalSize := m.totalSize
				// Overview paths are short; fixed width keeps layout stable.
				nameWidth := 20
				for idx, entry := range m.entries {
					icon := "📁"
					sizeVal := entry.Size
					barValue := max(sizeVal, 0)
					var percent float64
					if totalSize > 0 && sizeVal >= 0 {
						percent = float64(sizeVal) / float64(totalSize) * 100
					} else {
						percent = 0
					}
					percentStr := fmt.Sprintf("%5.1f%%", percent)
					if totalSize == 0 || sizeVal < 0 {
						percentStr = "  --  "
					}
					bar := coloredProgressBar(barValue, maxSize, percent)
					sizeText := "pending.."
					if sizeVal >= 0 {
						sizeText = humanizeBytes(sizeVal)
					}
					sizeColor := colorGray
					if sizeVal >= 0 && totalSize > 0 {
						switch {
						case percent >= 50:
							sizeColor = colorRed
						case percent >= 20:
							sizeColor = colorYellow
						case percent >= 5:
							sizeColor = colorBlue
						default:
							sizeColor = colorGray
						}
					}
					entryPrefix := "   "
					name := trimNameWithWidth(entry.Name, nameWidth)
					paddedName := padName(name, nameWidth)
					nameSegment := fmt.Sprintf("%s %s", icon, paddedName)
					numColor := ""
					percentColor := ""
					if idx == m.selected {
						entryPrefix = fmt.Sprintf(" %s%s▶%s ", colorCyan, colorBold, colorReset)
						nameSegment = fmt.Sprintf("%s%s %s%s", colorCyan, icon, paddedName, colorReset)
						numColor = colorCyan
						percentColor = colorCyan
						sizeColor = colorCyan
					}
					displayIndex := idx + 1

					var hintLabel string
					if entry.IsDir && isCleanableDir(entry.Path) {
						hintLabel = fmt.Sprintf("%s🧹%s", colorYellow, colorReset)
					} else {
						lastAccess := entry.LastAccess
						if lastAccess.IsZero() && entry.Path != "" {
							lastAccess = getLastAccessTime(entry.Path)
						}
						if unusedTime := formatUnusedTime(lastAccess); unusedTime != "" {
							hintLabel = fmt.Sprintf("%s%s%s", colorGray, unusedTime, colorReset)
						}
					}

					if hintLabel == "" {
						fmt.Fprintf(&b, "%s%s%2d.%s %s %s%s%s  |  %s %s%10s%s\n",
							entryPrefix, numColor, displayIndex, colorReset, bar, percentColor, percentStr, colorReset,
							nameSegment, sizeColor, sizeText, colorReset)
					} else {
						fmt.Fprintf(&b, "%s%s%2d.%s %s %s%s%s  |  %s %s%10s%s  %s\n",
							entryPrefix, numColor, displayIndex, colorReset, bar, percentColor, percentStr, colorReset,
							nameSegment, sizeColor, sizeText, colorReset, hintLabel)
					}
				}
			} else {
				maxSize := int64(1)
				for _, entry := range m.entries {
					if entry.Size > maxSize {
						maxSize = entry.Size
					}
				}

				viewport := calculateViewport(m.height, false)
				nameWidth := calculateNameWidth(m.width)
				start := max(m.offset, 0)
				end := min(start+viewport, len(m.entries))

				for idx := start; idx < end; idx++ {
					entry := m.entries[idx]
					icon := "📄"
					if entry.IsDir {
						icon = "📁"
					}
					size := humanizeBytes(entry.Size)
					name := trimNameWithWidth(entry.Name, nameWidth)
					paddedName := padName(name, nameWidth)

					percent := float64(entry.Size) / float64(m.totalSize) * 100
					percentStr := fmt.Sprintf("%5.1f%%", percent)

					bar := coloredProgressBar(entry.Size, maxSize, percent)

					var sizeColor string
					if percent >= 50 {
						sizeColor = colorRed
					} else if percent >= 20 {
						sizeColor = colorYellow
					} else if percent >= 5 {
						sizeColor = colorBlue
					} else {
						sizeColor = colorGray
					}

					isMultiSelected := m.multiSelected != nil && m.multiSelected[entry.Path]
					selectIcon := "○"
					nameColor := ""
					if isMultiSelected {
						selectIcon = fmt.Sprintf("%s●%s", colorGreen, colorReset)
						nameColor = colorGreen
					}

					entryPrefix := "   "
					nameSegment := fmt.Sprintf("%s %s", icon, paddedName)
					if nameColor != "" {
						nameSegment = fmt.Sprintf("%s%s %s%s", nameColor, icon, paddedName, colorReset)
					}
					numColor := ""
					percentColor := ""
					if idx == m.selected {
						entryPrefix = fmt.Sprintf(" %s%s▶%s ", colorCyan, colorBold, colorReset)
						if !isMultiSelected {
							nameSegment = fmt.Sprintf("%s%s %s%s", colorCyan, icon, paddedName, colorReset)
						}
						numColor = colorCyan
						percentColor = colorCyan
						sizeColor = colorCyan
					}

					displayIndex := idx + 1

					var hintLabel string
					if entry.IsDir && isCleanableDir(entry.Path) {
						hintLabel = fmt.Sprintf("%s🧹%s", colorYellow, colorReset)
					} else {
						lastAccess := entry.LastAccess
						if lastAccess.IsZero() && entry.Path != "" {
							lastAccess = getLastAccessTime(entry.Path)
						}
						if unusedTime := formatUnusedTime(lastAccess); unusedTime != "" {
							hintLabel = fmt.Sprintf("%s%s%s", colorGray, unusedTime, colorReset)
						}
					}

					if hintLabel == "" {
						fmt.Fprintf(&b, "%s%s %s%2d.%s %s %s%s%s  |  %s %s%10s%s\n",
							entryPrefix, selectIcon, numColor, displayIndex, colorReset, bar, percentColor, percentStr, colorReset,
							nameSegment, sizeColor, size, colorReset)
					} else {
						fmt.Fprintf(&b, "%s%s %s%2d.%s %s %s%s%s  |  %s %s%10s%s  %s\n",
							entryPrefix, selectIcon, numColor, displayIndex, colorReset, bar, percentColor, percentStr, colorReset,
							nameSegment, sizeColor, size, colorReset, hintLabel)
					}
				}
			}
		}
	}

	fmt.Fprintln(&b)
	if m.inOverviewMode() {
		if len(m.history) > 0 {
			fmt.Fprintf(&b, "%s↑↓←→ | Enter | R Refresh | O Open | F File | ← Back | Q Quit%s\n", colorGray, colorReset)
		} else {
			fmt.Fprintf(&b, "%s↑↓→ | Enter | R Refresh | O Open | F File | Q Quit%s\n", colorGray, colorReset)
		}
	} else if m.showLargeFiles {
		selectCount := len(m.largeMultiSelected)
		if selectCount > 0 {
			fmt.Fprintf(&b, "%s↑↓← | Space Select | R Refresh | O Open | F File | ⌫ Del(%d) | ← Back | Q Quit%s\n", colorGray, selectCount, colorReset)
		} else {
			fmt.Fprintf(&b, "%s↑↓← | Space Select | R Refresh | O Open | F File | ⌫ Del | ← Back | Q Quit%s\n", colorGray, colorReset)
		}
	} else {
		largeFileCount := len(m.largeFiles)
		selectCount := len(m.multiSelected)
		if selectCount > 0 {
			if largeFileCount > 0 {
				fmt.Fprintf(&b, "%s↑↓←→ | Space Select | Enter | R Refresh | O Open | F File | ⌫ Del(%d) | T Top(%d) | Q Quit%s\n", colorGray, selectCount, largeFileCount, colorReset)
			} else {
				fmt.Fprintf(&b, "%s↑↓←→ | Space Select | Enter | R Refresh | O Open | F File | ⌫ Del(%d) | Q Quit%s\n", colorGray, selectCount, colorReset)
			}
		} else {
			if largeFileCount > 0 {
				fmt.Fprintf(&b, "%s↑↓←→ | Space Select | Enter | R Refresh | O Open | F File | ⌫ Del | T Top(%d) | Q Quit%s\n", colorGray, largeFileCount, colorReset)
			} else {
				fmt.Fprintf(&b, "%s↑↓←→ | Space Select | Enter | R Refresh | O Open | F File | ⌫ Del | Q Quit%s\n", colorGray, colorReset)
			}
		}
	}
	if m.deleteConfirm && m.deleteTarget != nil {
		fmt.Fprintln(&b)
		var deleteCount int
		var totalDeleteSize int64
		if m.showLargeFiles && len(m.largeMultiSelected) > 0 {
			deleteCount = len(m.largeMultiSelected)
			for path := range m.largeMultiSelected {
				for _, file := range m.largeFiles {
					if file.Path == path {
						totalDeleteSize += file.Size
						break
					}
				}
			}
		} else if !m.showLargeFiles && len(m.multiSelected) > 0 {
			deleteCount = len(m.multiSelected)
			for path := range m.multiSelected {
				for _, entry := range m.entries {
					if entry.Path == path {
						totalDeleteSize += entry.Size
						break
					}
				}
			}
		}

		if deleteCount > 1 {
			fmt.Fprintf(&b, "%sDelete:%s %d items (%s)  %sPress ⌫ again  |  ESC cancel%s\n",
				colorRed, colorReset,
				deleteCount, humanizeBytes(totalDeleteSize),
				colorGray, colorReset)
		} else {
			fmt.Fprintf(&b, "%sDelete:%s %s (%s)  %sPress ⌫ again  |  ESC cancel%s\n",
				colorRed, colorReset,
				m.deleteTarget.Name, humanizeBytes(m.deleteTarget.Size),
				colorGray, colorReset)
		}
	}
	return b.String()
}

// calculateViewport returns visible rows for the current terminal height.
func calculateViewport(termHeight int, isLargeFiles bool) int {
	if termHeight <= 0 {
		return defaultViewport
	}

	reserved := 6 // Header + footer
	if isLargeFiles {
		reserved = 5
	}

	available := termHeight - reserved

	if available < 1 {
		return 1
	}
	if available > 30 {
		return 30
	}

	return available
}
